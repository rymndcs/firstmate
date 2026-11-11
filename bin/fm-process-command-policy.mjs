#!/usr/bin/env node
// Process selection policy; shell syntax belongs to fm-arm-command-policy.mjs.
import { readFileSync } from 'node:fs';
import {
  Lexer, splitProgram, commandPosition, shellInvocation, evalPayload,
  shellHeredocPayloads, shellHereStringPayloads,
} from './fm-arm-command-policy.mjs';

const advice = 'Use kill with explicit positive PID arguments obtained from a separate read-only inspection; pattern selections and unproven process groups can reach other agents.';
const basename = (value) => value.split('/').at(-1);
const literal = (word) => word?.literal && !word.unquotedExpansion && word.subs.length === 0;
const killMention = (source) => /\b(?:pkill|killall|kill)\b/.test(source.replace(/\\\r?\n|[\\'"]/g, ''));
const compound = new Set(['!', 'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'case', 'esac', 'do', 'done', 'function', 'time', 'coproc', 'select']);

function explicitKill(args) {
  if (args.some((word) => !literal(word))) return false;
  const values = args.map((word) => word.value);
  if (values.length === 1 && ['-l', '-L', '--list', '--help', '--version'].includes(values[0])) return true;
  let index = 0;
  if (values[0] === '-s' || values[0] === '-n') {
    if (!/^(?:[0-9]+|(?:SIG)?[A-Z][A-Z0-9]*)$/.test(values[1] || '')) return false;
    index = 2;
  } else if (/^-(?:[0-9]+|(?:SIG)?[A-Z][A-Z0-9]*)$/.test(values[0] || '')) index = 1;
  if (values[index] === '--') index++;
  return values.length > index && values.slice(index).every((value) => /^[1-9][0-9]*$/.test(value));
}

function unsafe(command, depth = 0) {
  if (depth > 12) return true;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return true;
  const program = splitProgram(lexed.tokens);
  const mentions = killMention(command) || lexed.tokens.some((token) => token.type === 'word' && killMention(token.value));
  for (const tokens of program.nodes) {
    let position = commandPosition(tokens);
    if (compound.has(position.words[0]?.value) && mentions) return true;
    for (const token of tokens) {
      if (token.type === 'group' && unsafe(token.content, depth + 1)) return true;
      if (token.type === 'word' && token.subs.some((sub) => unsafe(sub.content, depth + 1))) return true;
    }
    if (position.wrapperPayloads.some((payload) => unsafe(payload, depth + 1))) return true;
    while (position.command?.value === 'builtin') position = commandPosition(position.words.slice(position.index + 1));
    const name = basename(position.command?.value || '');
    if (position.unresolvedWrapperOption && killMention(command)) return true;
    if (position.command && !literal(position.command) && killMention(command)) return true;
    if (name === 'pkill' || name === 'killall') return true;
    const args = position.words.slice(position.index + 1);
    if (name === 'kill' && !explicitKill(args)) return true;
    if (['xargs', 'find'].includes(name) && mentions) return true;
    const shell = shellInvocation(position);
    if (shell?.kind === 'stdin' && program.separators.some((separator) => separator === '|' || separator === '|&') && mentions) return true;
    if (shell?.kind === 'command') {
      if (!literal(shell.payload)) return true;
      if (unsafe(shell.payload.value, depth + 1)) return true;
    }
    const evaluated = evalPayload(position);
    if (name === 'eval' && evaluated === null) return true;
    const payloads = [evaluated, ...shellHeredocPayloads(tokens, position), ...shellHereStringPayloads(tokens, position)];
    if (payloads.some((payload) => payload !== null && unsafe(payload, depth + 1))) return true;
  }
  return false;
}

try {
  let command;
  const args = process.argv.slice(2);
  if (args.length === 2 && args[0] === '--command') command = args[1];
  else if (args.length === 0) {
    const payload = JSON.parse(readFileSync(0, 'utf8'));
    command = payload.tool_input?.command;
  } else throw new Error('invalid hook arguments');
  if (typeof command !== 'string' || !command.trim()) throw new Error('missing command string');
  if (unsafe(command)) throw new Error('process selection cannot be proven safe');
} catch (error) {
  process.stderr.write(`${JSON.stringify({
    hookSpecificOutput: {hookEventName: 'PreToolUse', permissionDecision: 'deny'},
    systemMessage: `[process-kill] ${error.message}. ${advice}`,
  })}\n`);
  process.exitCode = 2;
}
