#!/usr/bin/env node
// Semantic policy for the ask-user gate: does a shell command actually INVOKE
// bin/fm-send.sh, as opposed to merely mentioning it?
//
// The gate denies the steer route out of an open ask-user finding, so a match on
// the bare substring `fm-send` also denies `cat bin/fm-send.sh`,
// `grep -rn fm-send bin/`, and `git log --oneline bin/fm-send.sh` - read-only
// inspection of the very script the gate is talking about. A guard that wedges
// diagnosis of itself is worse than the problem it solves, so the decision here
// is a command-word one: deny only when a command word whose basename is
// `fm-send.sh` is executed somewhere in the submitted program.
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

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

// True when this program executes the steer anywhere: at top level, inside a
// subshell or brace group, or inside a command substitution.
function invokesSteer(source, depth) {
  if (depth > MAX_NESTING) return false;
  const lexed = new Lexer(source).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The threat model is
  // agent mistakes - an ordinary steer always tokenizes - and here a fail-closed
  // choice would deny while an ask-user finding is open, which is exactly the
  // wedge this guard must not become.
  if (lexed.error) return false;

  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    // commandPosition skips leading assignments and wrappers (command, env,
    // sudo, nohup, timeout, exec) to reach the executed command word.
    const position = commandPosition(node);
    if (position.command && basename(position.command.value) === STEER_BASENAME) return true;
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
