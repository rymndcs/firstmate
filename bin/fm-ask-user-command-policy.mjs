#!/usr/bin/env node
// Semantic policy for the ask-user gate: does a shell command actually INVOKE
// bin/fm-send.sh, as opposed to merely mentioning it?
//
// The gate denies the steer route out of an open ask-user finding, so a match on
// the bare substring `fm-send` also denies `cat bin/fm-send.sh`,
// `grep -rn fm-send bin/`, and `git log --oneline bin/fm-send.sh` - read-only
// inspection of the very script the gate is talking about. A guard that wedges
// diagnosis of itself is worse than the problem it solves, so the decision here
// starts from command position: deny when a command word whose basename is
// `fm-send.sh` is executed somewhere in the submitted program, and allow the same
// path when it is an argument of a command that is only reading it.
//
// Command position alone is not enough, because a program can carry the steer
// somewhere the walk cannot place it - a `for` body, an `eval` argument. See "THE
// ESCALATION RULE" below for what happens then, and why it is the opposite of the
// guard's fail-safe rule rather than an exception to it.
//
// Unlike the cd-guard policy there is no persistence question. A steer inside a
// pipeline, a backgrounded job, a subshell, or any list position still delivers
// the steer, so every node counts and no node is skipped for running in a
// subshell context.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy never
// evaluates, expands, sources, or runs any byte of the submitted command; it
// inspects lexical command positions only. See docs/ask-user-guard.md for the
// contract, the empirically determined coverage, and the stated gaps.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The steer entry point, matched by basename so any path spelling reaching it
// counts.
const STEER_BASENAME = "fm-send.sh";

// Compound commands and command substitutions carry their own program text, and
// this policy re-lexes that text rather than guessing at it. The bound is a
// runaway-nesting backstop, far above anything a real command reaches.
const MAX_NESTING = 8;

// THE ESCALATION RULE, and why it is not the guard's fail-safe rule.
//
// Cannot prove it is NOT a steer -> deny. This is deliberately NOT the guard's
// fail-safe rule.
// Fail-safe covers STATE the guard cannot read - an unreadable status file, a
// missing tool, an unrecognized payload - and there the answer is allow and stay
// silent, because the guard has no business blocking work over its own blindness.
// This is the opposite case: the guard CAN read the command, and the command
// carries a token it cannot rule out as a steer. Denying is recoverable in one
// step, because the message names the skill to load. Allowing is not recoverable
// at all, because the steer goes out unchecked.
//
// Both rules stay intact in bin/fm-ask-user-pretool-check.sh: a missing Node, a
// missing policy file, or a policy answer the transport does not recognize still
// ALLOW silently, because that is unreadable state, not an unprovable command.
//
// Concretely, a word whose basename is fm-send.sh is allowed as plain data only
// when the node it sits in is a fully placed simple command whose command word is
// neither a shell reserved word nor a utility that executes what it is given.
// `cat bin/fm-send.sh` is placed, so the path is an argument and stays allowed.
// `do bin/fm-send.sh $w ok` is a compound-command body the node walk cannot
// place, and `eval`/`xargs` execute what they are handed, so both deny.

// Reserved words never head a simple command. splitProgram cuts on operators
// only, so a `for`/`while`/`until`/`if`/`case` body arrives as its own node
// headed by `do`, `then`, or `else`, and the walk cannot place anything in it.
const RESERVED_WORDS = new Set([
  "!", "[[", "]]", "case", "coproc", "do", "done", "elif", "else", "esac", "fi",
  "for", "function", "if", "in", "select", "then", "time", "until", "while", "{", "}",
]);

// Utilities whose documented purpose is to execute a command supplied in their
// arguments, so a steer path among those arguments is an invocation and not data.
// The wrappers commandPosition already resolves through (command, env, exec,
// nohup, sudo, timeout) are deliberately absent: it hands back the real command
// word for those, so they need no escalation.
const COMMAND_EXECUTORS = new Set([
  ".", "bash", "chroot", "dash", "doas", "eval", "flock", "ionice", "ksh", "nice",
  "parallel", "runuser", "setsid", "sh", "source", "ssh", "stdbuf", "su", "watch",
  "xargs", "zsh",
]);

// `find` only executes what it is given under the -exec family, and
// `find . -name fm-send.sh` is ordinary diagnosis, so it escalates on the flag
// rather than on the command word.
const FIND_EXEC_FLAGS = new Set(["-exec", "-execdir", "-ok", "-okdir"]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

// Byte-strip the syntax a shell joins within one word, then look for the steer
// basename. Used only where the walk has already failed to place a word, so it
// answers "could this be the steer?" rather than "is this the steer?".
function mentionsSteer(text) {
  return text.replace(/[\\'"]/g, "").includes(STEER_BASENAME);
}

// True when commandPosition placed this node as a plain simple command, so its
// remaining words are arguments rather than something waiting to be executed.
function isPlacedSimpleCommand(position) {
  if (position.unresolvedWrapperOption) return false;
  if (!position.command) return false;
  const name = basename(position.command.value);
  if (RESERVED_WORDS.has(name)) return false;
  if (COMMAND_EXECUTORS.has(name)) return false;
  if (name === "find") {
    return !position.words.slice(position.index + 1).some((word) => FIND_EXEC_FLAGS.has(word.value));
  }
  return true;
}

function nodeInvokesSteer(node, depth) {
  // commandPosition skips leading assignments and wrappers (command, env,
  // sudo, nohup, timeout, exec) to reach the executed command word.
  const position = commandPosition(node);

  for (const payload of position.wrapperPayloads ?? []) {
    if (invokesSteer(payload, depth + 1)) return true;
  }
  for (const token of node) {
    if (token.type === "group" && typeof token.content === "string") {
      if (invokesSteer(token.content, depth + 1)) return true;
      continue;
    }
    if (token.type !== "word") continue;
    for (const sub of token.subs ?? []) {
      if (sub.kind !== "command" || typeof sub.content !== "string") continue;
      if (invokesSteer(sub.content, depth + 1)) return true;
    }
  }

  if (position.command && basename(position.command.value) === STEER_BASENAME) return true;
  if (isPlacedSimpleCommand(position)) return false;
  return position.words.some((word) => mentionsSteer(word.value));
}

// True when this program executes the steer anywhere: at top level, inside a
// subshell or brace group, inside a command substitution, or inside a compound
// body or executor argument the walk cannot place.
function invokesSteer(source, depth) {
  if (depth > MAX_NESTING) return false;
  const lexed = new Lexer(source).tokenize();
  // Syntax this classifier cannot tokenize at all, such as a `case` list, is the
  // escalation rule's clearest case: the bytes are right here and they carry a
  // steer token the walk can no longer place. A program that does not mention the
  // steer is simply irrelevant to this guard and allows.
  if (lexed.error) return mentionsSteer(source);

  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    if (nodeInvokesSteer(node, depth)) return true;
  }
  return false;
}

function decision(command) {
  return invokesSteer(command, 0) ? { decision: "deny" } : { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      process.stdout.write(`${decision(args.command).decision}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
