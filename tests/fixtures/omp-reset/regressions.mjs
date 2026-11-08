import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync, unlinkSync, watch } from 'node:fs';
import { pathToFileURL } from 'node:url';
const home = process.env.FM_HOME;
const scenario = process.argv[2];
const { default: extension } = await import(pathToFileURL(`${home}/.omp/extensions/fm-primary-omp.ts`));
const chain = new Proxy(() => chain, { get: () => chain });
const handlers = new Map(), tools = new Map(), commands = new Map();
const messages = [], timers = [], submitted = [];
let queued = false;
let editor = '', jobs = null, session = 'old', terminalInput, switchMode = 'success', idle = true, switches = 0;
const pi = {
  zod: chain,
  on(name, fn) { const all = handlers.get(name) ?? []; all.push(fn); handlers.set(name, all); },
  registerTool(tool) { tools.set(tool.name, tool); },
  registerCommand(name, cmd) { commands.set(name, cmd); },
  sendMessage(message, options) { messages.push({ message, options, session }); },
};
const ctx = {
  agent: { kind: 'main' }, mode: 'tui', hasUI: true,
  sessionManager: { getSessionId: () => session, getSessionFile: () => '/old.jsonl' },
  isIdle: () => idle, hasPendingMessages: () => queued, getAsyncJobSnapshot: () => jobs,
  ui: { getEditorText: () => editor, setEditorText: value => { editor = value; }, notify() {},
    onTerminalInput(fn) { terminalInput = fn; return () => { terminalInput = undefined; }; } },
  setTimeout(fn, ms) { const t = { fn, ms }; timers.push(t); return t; },
  clearTimer(t) { const i = timers.indexOf(t); if (i >= 0) timers.splice(i, 1); },
  async newSession(options) {
    if (switchMode === 'cancel') { terminalInput = undefined; return { cancelled: true }; }
    if (switchMode === 'throw') { terminalInput = undefined; throw new Error('switch failed'); }
    if (switchMode === 'partial') { session = 'new'; terminalInput = undefined; throw new Error('partial switch'); }
    switches++; session = 'new'; jobs = null;
    await emit('session_switch');
    await options.setup({ appendMessage() {} });
    return { cancelled: false };
  },
};
async function emit(name, event = {}) {
  const results = [];
  for (const fn of handlers.get(name) ?? []) results.push(await fn(event, ctx));
  return results;
}
const call = params => tools.get('firstmate_watch_reset').execute('test', params, undefined, undefined, ctx);
const recoveries = () => messages.filter(x => x.message.customType === 'firstmate-reset-recovery' && x.options.triggerTurn);
const frame = nonce => `\x1b[?9001;${nonce.replaceAll('-', '').match(/.{4}/g).map(x => parseInt(x, 16)).join(';')}~`;
function input(data) {
  const result = terminalInput?.(data);
  if (result?.consume) return;
  const value = result?.data ?? data;
  if (value === '\r') { submitted.push(editor); editor = ''; }
  else editor += value;
}
async function arm({ command = 'exec bin/fm-watch-arm.sh', status = 'watcher: started pid=42 (beacon fresh)' } = {}) {
  jobs = { running: [{id:'watcher', type:'bash', command}], recent: [], delivery: { queued:0, delivering:false, pendingJobIds:[] } };
  await emit('tool_call', {toolName:'bash', input:{command,async:true,timeout:0}});
  await emit('tool_result', {toolName:'bash',input:{command,async:true,timeout:0},content:[{type:'text',text:'Async job running: watcher'}],isError:false});
  await emit('tool_result', {toolName:'read',input:{path:'proc://watcher'},content:[{type:'text',text:status}],isError:false});
  jobs = null;
}
async function ready() {
  const prep = await call({action:'prepare'});
  assert.equal(prep.isError, undefined, 'prepare must accept completed startup with only watching left');
  const n = prep.details.nonce;
  assert.ok(prep.content.some(x=>x.text?.includes(n)), 'prepare must expose its nonce in model-visible content');
  const result = await call({action:'ready',nonce:n,stowComplete:true,onlyKeepingWatch:true,handoff:'Open: backlog. Already reported: reply. Next: supervise.'});
  assert.equal(result.isError, undefined, 'readiness must accept only a confirmed supervision job');
  return n;
}
async function runSubmit() {
  const i = timers.findIndex(x => x.ms < 30000);
  assert.ok(i >= 0, 'ready must schedule submission even while the old supervision job defers session_stop');
  return timers.splice(i, 1)[0].fn();
}
function waitFile(path) {
  return new Promise(resolve => {
    if (existsSync(path)) return resolve();
    const w = watch(`${home}/state`, () => { if (existsSync(path)) { w.close(); resolve(); } });
  });
}
extension(pi);
await emit('session_start');
if (scenario === 'arm-gate') {
  jobs = {running:[],recent:[{id:'old-watcher',status:'cancelled',command:'exec bin/fm-watch-arm.sh'}],delivery:{queued:0,delivering:false,pendingJobIds:[]}};
  await emit('tool_result',{toolName:'read',input:{path:'proc://old-watcher'},isError:false,content:[{type:'text',text:'watcher: started pid=42 (beacon fresh)'}]});
  jobs = null;
  assert.equal((await call({action:'prepare'})).isError, true, 'old cancelled job output must not unlock reset in a new session');
  await emit('input', {text:'a request before startup arms'});
  assert.equal((await call({action:'prepare'})).isError, true, 'input must not unlock reset before a successful arm');
  await emit('tool_call',{toolName:'bash',input:{command:'cat bin/fm-watch-arm.sh'}});
  assert.equal((await call({action:'prepare'})).isError, true, 'cat must not unlock reset');
  const blocked = await emit('tool_call',{toolName:'bash',input:{command:'exec bin/fm-watch-arm.sh | head -1'}});
  assert.ok(blocked.some(x => x?.block), 'fixture must actually deny the arm');
  assert.equal((await call({action:'prepare'})).isError, true, 'seatbelt-denied arm must not unlock reset');
  await arm({status:'watcher: FAILED - no live watcher'});
  assert.equal((await call({action:'prepare'})).isError, true, 'failed arm must not unlock reset');
  await arm({command:'printf fake-status'});
  assert.equal((await call({action:'prepare'})).isError, true, 'status from a different command must not unlock reset');
  for (const status of ['watcher: started pid=42 (beacon fresh)','watcher: attached pid=42 (beacon 0s)']) {
    await arm({status});
    assert.equal((await call({action:'prepare'})).isError, undefined, 'successful arm must unlock reset');
  }
} else {
  await arm();
  await emit('input',{text:'an answered message'});
  if (scenario === 'running-watcher') {
    jobs = { running:[{id:'watcher',type:'bash',command:'exec bin/fm-watch-arm.sh'}],recent:[],delivery:{queued:0,delivering:false,pendingJobIds:[]} };
    const n = await ready();
    await runSubmit();
    input(frame(n));
    assert.deepEqual(submitted, [`/fm-reset ${n}`], 'only the registered command must reach Enter');
    await emit('input',{text:submitted[0]});
    await commands.get('fm-reset').handler(n, ctx);
    assert.equal(switches, 1, 'running supervision job must be cancelled by the native session switch');
    assert.equal(jobs, null);
    assert.equal(messages.filter(x=>x.message.customType==='firstmate-reset-start' && x.options.triggerTurn).length,1,'new session must receive exactly one startup turn');
  } else if (scenario.startsWith('veto-')) {
    const n = await ready();
    await runSubmit();
    if (scenario === 'veto-draft') editor = 'Wai';
    if (scenario === 'veto-busy') idle = false;
    if (scenario === 'veto-queued') queued = true;
    if (scenario === 'veto-foreign-job') jobs = {running:[{id:'watcher',command:'sleep 20'}],recent:[],delivery:{queued:0,delivering:false,pendingJobIds:[]}};
    const before = editor;
    input(frame(scenario === 'veto-forged' ? (n[0] === 'a' ? 'b' : 'a') + n.slice(1) : n));
    assert.deepEqual(submitted, [], `${scenario} must veto native Enter`);
    assert.equal(editor, before, `${scenario} must preserve the editor`);
  } else if (scenario === 'draft-race') {
    const n = await ready();
    await emit('session_stop');
    await runSubmit();
    input('W'); input('a'); input('i');
    input(frame(n));
    assert.deepEqual(submitted, [], 'interleaved draft must never be submitted');
    assert.equal(editor, 'Wai', 'trigger must be consumed without changing or submitting the draft');
  } else if (scenario === 'in-flight') {
    writeFileSync(`${home}/state/submit-pauses`, '');
    const n = await ready();
    await emit('session_stop');
    const submitting = runSubmit();
    await waitFile(`${home}/state/submit-started`);
    input('Wai');
    writeFileSync(`${home}/state/submit-resume`, 'continue\n');
    await submitting;
    unlinkSync(`${home}/state/submit-pauses`);
    assert.equal(editor,'Wai','cancellation must preserve draft');
    assert.equal(recoveries().length,1,'typing during the helper must request the old session recovery turn');
    assert.equal(recoveries()[0].session,'old');
    for (const t of timers.filter(x=>x.ms===30000)) await t.fn();
    await commands.get('fm-reset').handler(n,ctx);
    assert.equal(recoveries().length,1,'late deadline or command must not duplicate recovery');
  } else {
    switchMode = { 'cancelled-switch':'cancel','thrown-switch':'throw','partial-switch':'partial' }[scenario];
    assert.ok(switchMode, `unknown scenario ${scenario}`);
    const n = await ready();
    await commands.get('fm-reset').handler(n,ctx);
    const expectedType = switchMode === 'partial' ? 'firstmate-reset-start' : 'firstmate-reset-recovery';
    const turns = messages.filter(x=>x.message.customType===expectedType && x.options.triggerTurn);
    assert.equal(turns.length,1,`${scenario} must trigger exactly one recovery/startup turn`);
    assert.equal(turns[0].session,switchMode === 'partial' ? 'new' : 'old');
    assert.equal(typeof terminalInput, 'function', 'cancelled or thrown switch must restore the native input listener');
    if(switchMode === 'partial') assert.match(turns[0].message.content,/bin\/fm-session-start.sh/);
    assert.equal(switches,0);
  }
}
console.log(`ok - reset regression ${scenario}`);
