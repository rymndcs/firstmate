#!/usr/bin/env node
import { readFileSync } from 'node:fs';

const advice = "Use kill with explicit PID arguments; to search these names as text, split the word, e.g. grep -e 'pk''ill'.";
const bareLookup = /^\s*(?:command[ \t]+-[vV]|type|which)[ \t]+(?:pkill|killall)\s*$/;

try {
  let command;
  const args = process.argv.slice(2);
  if (args.length === 2 && args[0] === '--command') command = args[1];
  else if (args.length === 0) {
    const payload = JSON.parse(readFileSync(0, 'utf8'));
    command = payload.tool_input?.command;
  } else throw new Error('invalid hook arguments');
  if (typeof command !== 'string' || !command.trim()) throw new Error('missing command string');
  if (!bareLookup.test(command) && (
    /\b(?:pkill|killall)\b/.test(command)
    || (/\bpgrep\b/.test(command) && /\bkill\b/.test(command))
  )) throw new Error('blocked process-selection words');
} catch (error) {
  process.stderr.write(`${JSON.stringify({
    hookSpecificOutput: {hookEventName: 'PreToolUse', permissionDecision: 'deny'},
    systemMessage: `[process-kill] ${error.message}. ${advice}`,
  })}\n`);
  process.exitCode = 2;
}
