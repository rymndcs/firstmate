import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const home = process.env.FM_HOME;
const originalNow = Date.now;
let now = originalNow();
Date.now = () => now;
const { default: extension } = await import(pathToFileURL(`${home}/.omp/extensions/fm-primary-omp.ts`));
const chain = new Proxy(() => chain, { get: () => chain });
const handlers = new Map(), tools = new Map(), commands = new Map();
const messages = [], timers = [], seeds = [], notices = [];
let idle = true, queued = false, editor = '', jobs = null, switches = 0, cancelled = false;
let session = 'session-1';
const pi = {
  zod: chain,
  on(name, fn) { const all = handlers.get(name) ?? []; all.push(fn); handlers.set(name, all); },
  registerTool(tool) { tools.set(tool.name, tool); },
  registerCommand(name, cmd) { commands.set(name, cmd); },
  sendMessage(message, options) { messages.push({message, options}); },
};
let terminalInput;
const ctx = {
  agent: { kind: 'main' }, mode: 'tui', hasUI: true,
  sessionManager: { getSessionId: () => session, getSessionFile: () => '/old-session.jsonl' },
  isIdle: () => idle, hasPendingMessages: () => queued, getAsyncJobSnapshot: () => jobs,
  ui: { getEditorText: () => editor, notify: x => notices.push(x),
    onTerminalInput(fn) { terminalInput = fn; return () => {}; } },
  setTimeout(fn, ms) { timers.push({fn, ms}); return fn; }, clearTimer() {},
  async newSession(options) {
    if (cancelled) return { cancelled: true };
    switches++; session = `session-${switches + 1}`;
    await emit('session_switch', {}, ctx);
    await options.setup({ appendMessage: msg => seeds.push(msg), getSessionId: () => session });
    return { cancelled: false };
  },
};
async function emit(name, event = {}, context = ctx) {
  for (const handler of handlers.get(name) ?? []) await handler(event, context);
}
function text(result) { return result.content.map(x => x.text ?? '').join('\n'); }
extension(pi);
const tool = tools.get('firstmate_watch_reset');
assert.ok(tool, 'primary extension must register firstmate_watch_reset');
assert.ok(commands.has('fm-reset'), 'primary extension must register fm-reset');
const call = params => tool.execute('tool-id', params, undefined, undefined, ctx);
await emit('session_start');
async function arm() {
  jobs = {running:[{id:'watcher',command:'exec bin/fm-watch-arm.sh'}],recent:[],delivery:{queued:0,delivering:false,pendingJobIds:[]}};
  await emit('tool_result',{toolName:'bash',toolCallId:'arm-call',input:{},details:{async:{state:'running',jobId:'watcher',type:'bash'}},isError:false,content:[]});
  writeFileSync(`${home}/state/.omp-watch-arm-result`, `${session}\narm-call\nwatcher: started pid=42 (beacon fresh)\n`);
  await emit('tool_result',{toolName:'read',input:{path:'proc://watcher'},isError:false,content:[{type:'text',text:'watcher: started pid=42 (beacon fresh)'}]});
  jobs = null;
}
await arm();
await emit('input' , { text: 'Delegate this work.' });
async function prepare() {
  const result = await call({ action: 'prepare' });
  assert.equal(result.isError, undefined, text(result));
  assert.ok(result.details.nonce);
  return result.details.nonce;
}
async function ready(nonce, overrides = {}) {
  return call({ action: 'ready', nonce, stowComplete: true, onlyKeepingWatch: true, pendingQuestionsRecorded: true,
    stowReceipt: {effectiveBudgetTokens:'4800',totalTokensBefore:'0',totalTokensAfter:'0',actions:{'data/captain.md':'unchanged','data/captain-shared.md':'unchanged','data/learnings.md':'unchanged'}},
    handoff: 'Open threads: data/backlog.md#reset-followup. Already reported: investigation result delivered. Next: watch.', ...overrides });
}
async function submittedToken() {
  const result = await ready(await prepare());
  assert.equal(result.isError, undefined, text(result));
  await emit('session_stop', { stop_hook_active: false });
  const next = timers.findLastIndex(x => x.ms < 30000);
  assert.ok(next >= 0, "reset must schedule submission");
  await timers.splice(next, 1)[0].fn();
  return readFileSync(`${home}/state/submissions`, 'utf8').trim().split('\n').at(-1);
}
const nonce = await prepare();
await emit('tool_call', {toolName:'bash',input:{command:'bin/fm-startup-memory-budget.sh report'}});
assert.match(text(await ready(nonce, {stowComplete:false})), /stow/i);
await commands.get('fm-reset').handler(nonce, ctx);
assert.equal(switches, 0, 'failed stow must leave session intact');
let n = await prepare();
assert.equal((await ready(n, {nonce:'incorrect'})).isError, true, 'wrong nonce cannot attest readiness');
n = await prepare();
assert.equal((await ready(n, {onlyKeepingWatch:false})).isError, true, 'unfinished work cannot attest readiness');
n = await prepare();
await emit('input', { text: 'Wait, new instruction.' });
assert.equal((await ready(n)).isError, true, 'new input invalidates stow preparation');
n = await prepare(); editor = 'half typed';
assert.equal((await ready(n)).isError, true, 'draft blocks readiness'); editor = '';
n = await prepare(); queued = true;
assert.equal((await ready(n)).isError, true, 'queued input blocks readiness'); queued = false;
n = await prepare(); jobs = { running: [{ id: 'foreign-work' }], delivery: {queued:0,delivering:false,pendingJobIds:[]} };
assert.equal((await ready(n)).isError, true, 'live job prevents resetting'); jobs = null;
for (const delivery of [
  {queued:1,delivering:false,pendingJobIds:[]},
  {queued:0,delivering:true,pendingJobIds:[]},
  {queued:0,delivering:false,pendingJobIds:['completed-watcher']},
]) {
  n = await prepare(); jobs = {running:[],delivery};
  assert.equal((await ready(n)).isError, true, 'queued async completion prevents resetting'); jobs = null;
}
n = await prepare(); writeFileSync(`${home}/state/over-budget`, '');
assert.equal((await ready(n)).isError, true, 'over-budget stow prevents resetting'); unlinkSync(`${home}/state/over-budget`);
n = await prepare(); writeFileSync(`${home}/state/budget-fails`, '');
assert.equal((await ready(n)).isError, true, 'failed budget measurement prevents resetting'); unlinkSync(`${home}/state/budget-fails`);
n = await prepare(); await ready(n); now += 60000;
await commands.get('fm-reset').handler(n, ctx);
assert.equal(switches, 0, 'expired readiness cannot reset');
now = originalNow();
n = await prepare(); await ready(n); terminalInput('x');
await commands.get('fm-reset').handler(n, ctx);
assert.equal(switches, 0, 'new keystroke cancels reset');
n = await prepare(); await ready(n); await emit('tool_call', {toolName: 'bash', input: {command: 'perform more work'}});
await commands.get('fm-reset').handler(n, ctx);
assert.equal(switches, 0, 'further work invalidates readiness');
await submittedToken();
const deadline = timers.findLast(x => x.ms === 30000);
const recoveryCount = messages.length;
await deadline.fn();
assert.ok(messages.length > recoveryCount, 'unacknowledged command must restore supervision');
const token = await submittedToken();
assert.match(token, /^[a-f0-9-]+$/);
assert.ok(existsSync(`${home}/state/.omp-reset-handoff.json`), 'handoff must be durable before submission');
await emit('input', { text: `/fm-reset ${token}` });
await commands.get('fm-reset').handler(token, ctx);
assert.equal(switches, 1);
assert.equal(seeds.length, 1);
assert.match(seeds[0].content[0].text, /bin\/fm-session-start.sh/);
assert.match(seeds[0].content[0].text, /Open threads: data\/backlog\.md#reset-followup/);
assert.match(seeds[0].content[0].text, /Already reported: investigation result delivered/);
assert.equal(messages.filter(x => x.message.customType === 'firstmate-reset-start' && x.options?.triggerTurn).length, 1, 'new session must start one turn');
assert.match(messages.find(x => x.message.customType === 'firstmate-reset-start').message.content, /bin\/fm-session-start.sh/, 'triggered turn must receive the full seed without relying on setup-only history');
assert.match(messages.find(x => x.message.customType === 'firstmate-reset-start').message.content, /Open threads: data\/backlog\.md#reset-followup/, 'triggered startup must retain the specific open-thread pointer');
assert.match(messages.find(x => x.message.customType === 'firstmate-reset-start').message.content, /Already reported: investigation result delivered/, 'triggered startup must retain the specific already-reported outcome');
await commands.get('fm-reset').handler(token, ctx);
assert.equal(switches, 1, 'token cannot replay');
assert.equal((await call({action:'prepare'})).isError, true, 'startup handoff cannot cause a reset loop');
await arm();
assert.equal((await call({action:'prepare'})).isError, undefined, 'normal supervision enables future resets');
await emit('input', {text:'Continue'});
writeFileSync(`${home}/state/submit-fails`, '');
const before = messages.length;
await submittedToken();
assert.ok(messages.length > before, 'failed submit must request supervision recovery');
unlinkSync(`${home}/state/submit-fails`);
await emit('input', {text:'Continue'});
n = await prepare(); await ready(n); queued = true;
await commands.get('fm-reset').handler(n, ctx);
assert.equal(switches, 1, 'command must recheck queued input'); queued = false;
n = await prepare(); await ready(n); idle = false;
await commands.get('fm-reset').handler(n, ctx);
assert.equal(switches, 1, 'command must recheck native idle'); idle = true;
n = await prepare(); await ready(n); cancelled = true;
await commands.get('fm-reset').handler(n, ctx);
assert.equal(switches, 1, 'cancelled session switch must not claim success');
await emit('input', {text:'Another normal request'});
const sub = {...ctx,agent:{kind:'sub'}};
assert.equal((await tool.execute('sub', {action:'prepare'}, undefined, undefined, sub)).isError, true);
const print = {...ctx,mode:'print'};
assert.equal((await tool.execute('print', {action:'prepare'}, undefined, undefined, print)).isError, true);
writeFileSync(`${home}/state/refuse`, '');
const unownedMessages = messages.length;
await commands.get('fm-reset').handler('unowned', ctx);
assert.equal(messages.length, unownedMessages, 'unowned home must not receive an automatic recovery turn');
assert.equal((await call({action:'prepare'})).isError, true, 'nonprimary or unowned home is refused');
Date.now = originalNow;
console.log('ok - registered reset: stow, idle, input, expiry, handoff, switch, recovery, and loop prevention');
