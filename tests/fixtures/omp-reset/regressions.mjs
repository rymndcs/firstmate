import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync, watch } from 'node:fs';
import { pathToFileURL } from 'node:url';
const home = process.env.FM_HOME;
const scenario = process.argv[2];
const { default: extension } = await import(pathToFileURL(`${home}/.omp/extensions/fm-primary-omp.ts`));
const chain = new Proxy(() => chain, { get: () => chain });
const handlers = new Map(), tools = new Map(), commands = new Map();
const messages = [], timers = [], submitted = [], errors = [];
let enqueueFailures = 0, enqueueCalls = 0;
let queued = false;
let contextUsage = { tokens: 60000, contextWindow: 100000, percent: 60 };
let editor = '', jobs = null, session = 'old', terminalInput, switchMode = 'success', idle = true, switches = 0;
const pi = {
  zod: chain,
  on(name, fn) { const all = handlers.get(name) ?? []; all.push(fn); handlers.set(name, all); },
  registerTool(tool) { tools.set(tool.name, tool); },
  registerCommand(name, cmd) { commands.set(name, cmd); },
  sendMessage(message, options) {
    enqueueCalls++;
    if (enqueueFailures-- > 0) throw new Error('injected enqueue failure');
    messages.push({ message, options, session });
  },
};
const ctx = {
  agent: { kind: 'main' }, mode: 'tui', hasUI: true,
  sessionManager: { getSessionId: () => session, getSessionFile: () => '/old.jsonl' },
  isIdle: () => idle, hasPendingMessages: () => queued, getAsyncJobSnapshot: () => jobs,
  getContextUsage: () => contextUsage,
  ui: { getEditorText: () => editor, setEditorText: value => { editor = value; },
    notify(text, type) { errors.push({ text, type, session }); },
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
function classify(content) {
  const result = spawnSync('bash', ['-c', `
    . "$1/bin/fm-supervise-daemon.sh"
    message=$(cat)
    kind=$(printf '%s' "$message" | "$1/bin/fm-operational-input.sh" kind)
    classified=$(printf '%s' "$message" | "$1/bin/fm-operational-input.sh" classify)
    if should_exit_afk "$2" "$message"; then returns=yes; else returns=no; fi
    printf '%s\\t%s\\t%s' "$kind" "$classified" "$returns"
  `, '_', process.env.FM_RESET_SOURCE_ROOT, `${home}/state/classifier-away`], { input: content, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.split('\t');
}
function assertOperational(message) {
  const kind = message.customType === 'firstmate-reset-start' ? 'session-start' : 'watcher';
  const classification = classify(message.content);
  assert.deepEqual(classification, [kind, kind, 'no'], `${scenario}: ${message.customType} must parse as internal and must not end away mode; got ${JSON.stringify(classification)} for ${JSON.stringify(message.content)}`);
  const owner = `${process.env.FM_RESET_SOURCE_ROOT}/bin/fm-operational-input.sh`;
  const body = spawnSync(owner, ['body'], { input: message.content, encoding: 'utf8' });
  assert.equal(body.status, 0, body.stderr);
  const encoded = spawnSync(owner, ['encode', kind], { input: body.stdout, encoding: 'utf8' });
  assert.equal(encoded.status, 0, encoded.stderr);
  assert.equal(message.content, encoded.stdout, 'reset messages must retain the exact owned protocol bytes');
  assert.match(body.stdout, kind === 'watcher' ? /^Automatic reset deferred:/ : /^Run `bin\/fm-session-start.sh`/);
}
const frame = nonce => `\x1b[?9001;${nonce.replaceAll('-', '').match(/.{4}/g).map(x => parseInt(x, 16)).join(';')}~`;
function input(data) {
  const result = terminalInput?.(data);
  if (result?.consume) return;
  const value = result?.data ?? data;
  if (value === '\r') { submitted.push(editor); editor = ''; }
  else editor += value;
}
async function arm({ command = 'exec bin/fm-watch-arm.sh', status = 'watcher: started pid=42 (beacon fresh)', receipt = true, receiptSession = session, receiptCall = 'arm-call', outputStatus = status, nativeState = 'running', nativeError = false } = {}) {
  jobs = { running: [{id:'watcher', type:'bash', command}], recent: [], delivery: { queued:0, delivering:false, pendingJobIds:[] } };
  await emit('tool_call', {toolName:'bash', input:{command,async:true,timeout:0}});
  await emit('tool_result', {toolName:'bash',toolCallId:'arm-call',input:{command,async:true,timeout:0},details:{async:{state:nativeState,jobId:'watcher',type:'bash'}},content:[{type:'text',text:'Async job running: watcher'}],isError:nativeError});
  if (receipt) writeFileSync(`${home}/state/.omp-watch-arm-result`, `${receiptSession}\n${receiptCall}\n${status}\n`);
  else if (existsSync(`${home}/state/.omp-watch-arm-result`)) unlinkSync(`${home}/state/.omp-watch-arm-result`);
  await emit('tool_result', {toolName:'read',input:{path:'proc://watcher'},content:[{type:'text',text:outputStatus}],isError:false});
  const seeded = spawnSync(`${home}/bin/fm-omp-watch-transition.sh`, ['arm', 'work-pending', 'registered extension fixture'], {
    env: { ...process.env, OMPCODE: '1', PI_SESSION_ID: session, PI_TOOL_CALL_ID: 'arm-call' }, encoding: 'utf8',
  });
  assert.ok(seeded.status === 0 || seeded.status === 3, seeded.stderr);
  jobs = null;
}
const stowReceipt = () => ({effectiveBudgetTokens:'4800',totalTokensBefore:'0',totalTokensAfter:'0',actions:{
  'data/captain.md':'unchanged','data/captain-shared.md':'unchanged','data/learnings.md':'unchanged',
}});
async function ready() {
  const prep = await call({action:'prepare'});
  assert.equal(prep.isError, undefined, 'prepare must accept completed startup with only watching left');
  const n = prep.details.nonce;
  assert.ok(prep.content.some(x=>x.text?.includes(n)), 'prepare must expose its nonce in model-visible content');
  const result = await call({action:'ready',nonce:n,stowComplete:true,onlyKeepingWatch:true,pendingQuestionsRecorded:true,stowReceipt:stowReceipt(),handoff:'Open: backlog. Already reported: reply. Next: supervise.'});
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
function admitHeartbeat() {
  const env = { ...process.env, OMPCODE: '1', PI_SESSION_ID: session, PI_TOOL_CALL_ID: 'arm-call' };
  for (const args of [
    [`${home}/bin/fm-omp-watch-transition.sh`, 'cycle', 'wake', '42', 'fixture'],
    ['bash', '-c', '. "$1"; fm_wake_append heartbeat fixture "heartbeat: fixture"', '_', `${home}/bin/fm-wake-lib.sh`],
    [`${home}/bin/fm-wake-drain.sh`],
  ]) {
    const result = spawnSync(args[0], args.slice(1), { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  }
}
let rearmCalls = 0;
async function rearm(context = ctx, claim = '') {
  const event = { toolName: 'bash', toolCallId: `after-context-refusal-${++rearmCalls}`, input: {
    command: `[ -f config/x-mode.env ] && . config/x-mode.env; exec bin/fm-watch-arm.sh${claim}`,
    async: true, timeout: 0,
  } };
  let input = event.input;
  for (const handler of handlers.get('tool_call') ?? []) {
    const result = await handler({ ...event, input }, context);
    assert.notEqual(result?.block, true, 'plain tracked arm must pass the existing command guards');
    input = result?.input ?? input;
  }
  assert.equal(input.async, true, 'context transport must retain native tracked execution');
  assert.equal(input.timeout, 0, 'context transport must retain the unbounded arm timeout');
  return spawnSync('bash', ['-c', input.command], { cwd: home, encoding: 'utf8', env: {
    ...process.env, OMPCODE: '1', PI_SESSION_ID: session, PI_TOOL_CALL_ID: event.toolCallId,
    FM_OMP_CONTEXT_PERCENT: '60',
  } });
}
extension(pi);
mkdirSync(`${home}/state/classifier-away`, { recursive: true });
writeFileSync(`${home}/state/classifier-away/.afk`, '');
assert.deepEqual(classify('I am back; please show the investigation results.'), ['', '', 'yes'], 'a real human return must remain unmarked and end away mode');
await emit('session_start');
if (scenario === 'context-rearm-fresh' || scenario === 'context-rearm-isolation') {
  await arm();
  admitHeartbeat();
  contextUsage = { tokens: 39990, contextWindow: 100000, percent: 39.99 };
  assert.equal((await call({ action: 'prepare' })).isError, true);
  if (scenario === 'context-rearm-isolation') {
    for (const context of [{ ...ctx, agent: { kind: 'sub' } }, { ...ctx, mode: 'print' }]) {
      const result = await rearm(context);
      assert.equal(result.status, 2, 'nonprimary context must not replace the primary measurement');
      assert.match(result.stderr, /reset required/);
    }
  } else {
    contextUsage = { tokens: 40001, contextWindow: 100000, percent: 40.001 };
    const high = await rearm();
    assert.equal(high.status, 2, 'a refused low preparation must not exempt a later high-context arm');
    assert.match(high.stderr, /reset required/);
    contextUsage = undefined;
    const unavailable = await rearm();
    assert.equal(unavailable.status, 0, 'unavailable usage must replace the prior high measurement');
    assert.match(unavailable.stdout, /heartbeat: fixture/);
  }
} else if (scenario.startsWith('context-')) {
  await arm();
  const previousNonce = (await call({action:'prepare'})).details.nonce;
  assert.ok(previousNonce, 'high context must prepare before testing a changed measurement');
  const kind = scenario.slice('context-'.length);
  const percent = {zero:0,below:39.99,boundary:40,above:40.01,high:80,unknown:null,nan:NaN}[kind];
  contextUsage = kind === 'unavailable' ? undefined : {tokens:percent * 1000,contextWindow:100000,percent};
  const result = await call({action:'prepare'});
  admitHeartbeat();
  for (const claim of ['', ' --transition watching-only --reason "only watching remains"']) {
    const continuation = await rearm(ctx, claim);
    assert.equal(continuation.status, kind === 'above' || kind === 'high' ? 2 : 0,
      `${scenario}: real plain/watching-only arm must follow the current context threshold; ${continuation.stderr}`);
    if (kind === 'above' || kind === 'high') assert.match(continuation.stderr, /reset required/);
    else {
      assert.match(continuation.stdout, /heartbeat: fixture/, 'permitted arm must reach its actual watcher child');
      const record = JSON.parse(readFileSync(`${home}/state/.omp-watch-transition`, 'utf8'));
      assert.equal(record.decision.verdict, 'allow');
      admitHeartbeat();
    }
  }
  if (kind === 'above' || kind === 'high') {
    assert.equal(result.isError, undefined, `${scenario}: context above 40% must prepare`);
    const nonce = result.details.nonce;
    assert.ok(nonce, 'accepted preparation must return a fresh nonce');
    const accepted = await call({action:'ready',nonce,stowComplete:true,onlyKeepingWatch:true,
      pendingQuestionsRecorded:true,stowReceipt:stowReceipt(),handoff:'Next: supervise.'});
    assert.equal(accepted.isError, undefined, 'eligible context must retain readiness');
    await commands.get('fm-reset').handler(nonce, ctx);
    assert.equal(switches, 1, 'eligible context must retain native reset');
    unlinkSync(`${home}/state/.omp-reset-handoff.json`);
  } else {
    assert.equal(result.isError, true, `${scenario}: context at or below 40% or unavailable must refuse preparation`);
    assert.equal(result.details.nonce, undefined, 'refused preparation must not return a nonce');
    const text = result.content.map(x => x.text ?? '').join('\n');
    assert.match(text, /plain re-arm/i, 'refusal must direct a plain re-arm');
    assert.doesNotMatch(text, /# stow/, 'refusal must not start the stow skill');
    const refused = await call({action:'ready',nonce:previousNonce,stowComplete:true,onlyKeepingWatch:true,
      pendingQuestionsRecorded:true,stowReceipt:stowReceipt(),handoff:'Next: supervise.'});
    assert.equal(refused.isError, true, 'refusal must invalidate an earlier preparation');
    assert.equal(timers.length, 0, 'refusal must not schedule transport');
    assert.equal(existsSync(`${home}/state/.omp-reset-handoff.json`), false, 'refusal must not save a handoff');
    await commands.get('fm-reset').handler(previousNonce, ctx);
    assert.equal(switches, 0, 'refusal must preserve the current session');
    assert.deepEqual(messages, [], 'refusal must not queue another turn');
  }
} else if (scenario.startsWith('questions-')) {
  await arm();
  const nonce = (await call({action:'prepare'})).details.nonce;
  const params = {action:'ready',nonce,stowComplete:true,onlyKeepingWatch:true,
    stowReceipt:stowReceipt(),handoff:'Open question: should I push? Next: supervise.'};
  const kind = scenario.slice('questions-'.length);
  if (kind !== 'missing') params.pendingQuestionsRecorded = {false:false,string:'true',valid:true}[kind];
  const result = await call(params);
  if (kind === 'valid') {
    assert.equal(result.isError, undefined, 'recorded questions must allow readiness');
    assert.equal(timers.filter(x => x.ms < 30000).length, 1, 'attested readiness must schedule reset');
    await commands.get('fm-reset').handler(nonce, ctx);
    assert.equal(switches, 1, 'attested readiness must still reset');
  } else {
    assert.equal(result.isError, true, `${scenario}: chat-only questions must block readiness without a true attestation`);
    assert.match(result.content.map(x => x.text ?? '').join('\n'), /pendingQuestionsRecorded/, 'refusal must name the missing attestation');
    assert.equal(timers.length, 0, 'refused attestation must not schedule reset');
    assert.equal(existsSync(`${home}/state/.omp-reset-handoff.json`), false, 'refused attestation must not save a handoff');
    await commands.get('fm-reset').handler(nonce, ctx);
    assert.equal(switches, 0, 'refused attestation must preserve this session');
  }
} else if (scenario.startsWith('receipt-')) {
  await arm();
  const nonce = (await call({action:'prepare'})).details.nonce;
  const receipt = stowReceipt();
  const kind = scenario.slice('receipt-'.length);
  if (['after','before','budget'].includes(kind)) delete receipt[{after:'totalTokensAfter',before:'totalTokensBefore',budget:'effectiveBudgetTokens'}[kind]];
  if (kind.startsWith('action-')) {
    const file = {captain:'captain.md',shared:'captain-shared.md',learnings:'learnings.md'}[kind.slice(7)];
    if (file) delete receipt.actions[`data/${file}`];
    else receipt.actions['data/captain.md'] = 'skipped';
  }
  if (kind === 'before-invalid') receipt.totalTokensBefore = 'unknown';
  if (kind === 'mismatch') receipt.totalTokensAfter = '1';
  if (kind === 'budget-mismatch') receipt.effectiveBudgetTokens = '4801';
  if (kind === 'over-budget' || kind === 'valid') {
    writeFileSync(`${home}/config/startup-memory-budget`, '2\n');
    writeFileSync(`${home}/data/captain.md`, kind === 'valid' ? 'abc' : 'abcdefghi');
    receipt.effectiveBudgetTokens = '2'; receipt.totalTokensBefore = '9';
    receipt.totalTokensAfter = kind === 'valid' ? '1' : '3';
    if (kind === 'valid') { receipt.actions['data/captain.md'] = 'rewritten'; receipt.actions['data/learnings.md'] = 'routed'; }
  }
  if (kind === 'report-missing-total' || kind === 'report-missing-budget') writeFileSync(`${home}/state/${kind}`, '');
  const result = await call({action:'ready',nonce,stowComplete:true,onlyKeepingWatch:true,pendingQuestionsRecorded:true,
    stowReceipt:kind === 'missing' ? undefined : receipt,handoff:'Open: backlog. Already reported: reply. Next: supervise.'});
  if (kind === 'valid') {
    assert.equal(result.isError, undefined, 'complete matching receipt must accept readiness');
    assert.deepEqual(result.details.stowReceipt, receipt, 'ready must return the verified receipt');
    assert.equal(result.details.budgetVerified, true, 'ready result must witness the extension budget recheck');
  } else {
    assert.equal(result.isError, true, `${scenario}: incomplete or unverified stow receipt must refuse readiness`);
    assert.equal(timers.length, 0, 'refused receipt must not schedule reset');
    await commands.get('fm-reset').handler(nonce, ctx);
    assert.equal(switches, 0, 'refused receipt must preserve this session');
  }
  writeFileSync(`${home}/config/startup-memory-budget`, '4800\n');
  for (const file of ['data/captain.md','state/report-missing-total','state/report-missing-budget']) {
    if (existsSync(`${home}/${file}`)) unlinkSync(`${home}/${file}`);
  }
} else if (scenario.startsWith('startup-') || scenario.startsWith('recovery-')) {
  const checks = () => existsSync(`${home}/state/recovery-checks`)
    ? readFileSync(`${home}/state/recovery-checks`, 'utf8').trim().split('\n').length : 0;
  const checksBefore = checks();
  await arm();
  const n = await ready();
  const startup = scenario.startsWith('startup-');
  const refused = scenario === 'startup-refused';
  const recoveryFails = !startup || scenario.startsWith('startup-recovery-') || refused;
  if (refused) {
    switchMode = 'throw';
    writeFileSync(`${home}/state/recovery-refused`, '');
  }
  if (scenario.endsWith('encoding')) {
    writeFileSync(`${home}/state/encoding-failures`, startup ? recoveryFails ? '2,3' : '2' : '1');
    if (existsSync(`${home}/state/encoding-count`)) unlinkSync(`${home}/state/encoding-count`);
  }
  enqueueFailures = scenario.endsWith('enqueue') ? startup && recoveryFails ? 2 : 1 : 0;
  await assert.doesNotReject(async () => {
    if (startup) await commands.get('fm-reset').handler(n, ctx);
    else {
      input('Wai');
      await runSubmit();
      assert.equal(editor, 'Wai', 'failed recovery must retain the human draft');
    }
  }, `${scenario}: recovery must report delivery failure rather than throw it out of the callback`);
  assert.equal(switches, startup && !refused ? 1 : 0, 'fault must reach the intended switch boundary');
  assert.equal(checks(), checksBefore + 1, `${scenario}: delivery failure must reach the independent recovery check`);
  if (!refused) {
    const continuation = spawnSync(`${home}/bin/fm-watch-arm.sh`, [], {
      env: { ...process.env, OMPCODE: '1', PI_SESSION_ID: session, PI_TOOL_CALL_ID: 'recovery-continuation' }, encoding: 'utf8',
    });
    assert.equal(continuation.status, 0, continuation.stderr);
    const verdict = JSON.parse(readFileSync(`${home}/state/.omp-watch-transitions.log`, 'utf8').trim().split('\n').at(-1));
    assert.equal(verdict.observed, startup ? 'startup' : 'recovery', 'actual receiving session must arm through its verified exemption');
  }
  const turns = messages.filter(x => x.options?.triggerTurn);
  assert.equal(turns.length, recoveryFails ? 0 : 1, `${scenario}: queue exactly one continuation when recovery succeeds`);
  assert.equal(enqueueCalls, scenario.endsWith('enqueue') ? startup ? 2 : 1 : recoveryFails ? 0 : 1,
    'delivery failure must use one recovery attempt without a send retry loop');
  if (scenario.endsWith('encoding')) {
    assert.equal(Number(readFileSync(`${home}/state/encoding-count`, 'utf8')), startup ? 3 : 1,
      'encoding failure must use one recovery attempt without an encoder retry loop');
  }
  if (!recoveryFails) {
    assert.equal(turns[0].session, 'new');
    assert.match(turns[0].message.content, /bin\/fm-session-start\.sh/);
    assert.match(turns[0].message.content, /arm exactly one supervision cycle/);
    assert.match(turns[0].message.content, /Open: backlog\. Already reported: reply/);
  }
  assert.equal(errors.some(x => x.text.includes('Supervision recovery requested.')), !recoveryFails,
    `${scenario}: recovery requested notice must reflect accepted submission only`);
  assert.equal(errors.length, 1, `${scenario}: report one failure without a contradictory extra notice`);
  const failure = errors.find(x => x.text.startsWith(recoveryFails && !refused ? 'Automatic reset recovery failed:' : 'Automatic reset failed:'));
  assert.ok(failure, `${scenario}: failed delivery must leave a visible failure line through the native error UI`);
  assert.equal(failure.type, 'error', 'only the error UI is verified to render a chat error line');
  assert.equal(failure.session, startup && !refused ? 'new' : 'old');
  assert.match(failure.text, refused ? /switch failed/ : /injected (encoding|enqueue) failure/);
  if (recoveryFails && !refused) assert.match(failure.text, /could not be queued/);
  const before = { messages: messages.length, errors: errors.length, enqueueCalls,
    encodings: existsSync(`${home}/state/encoding-count`) ? readFileSync(`${home}/state/encoding-count`, 'utf8') : '' };
  for (const t of timers) await t.fn();
  await commands.get('fm-reset').handler(n, ctx);
  assert.deepEqual({ messages: messages.length, errors: errors.length, enqueueCalls,
    encodings: existsSync(`${home}/state/encoding-count`) ? readFileSync(`${home}/state/encoding-count`, 'utf8') : '' }, before,
    'late deadline, submit and command must not retry or duplicate the completed recovery attempt');
  if (refused) unlinkSync(`${home}/state/recovery-refused`);
  if (existsSync(`${home}/state/encoding-failures`)) unlinkSync(`${home}/state/encoding-failures`);
} else if (scenario.startsWith('away-')) {
  const [, signal, ...parts] = scenario.split('-');
  const phase = parts.join('-');
  const presence = `${home}/state/${signal === 'flag' ? '.afk' : '.afk-daemon-terminal'}`;
  const enterAway = () => writeFileSync(presence, signal === 'flag' ? '' : 'none\t-\tomp\n');
  const beforeSubmissions = existsSync(`${home}/state/submissions`) ? readFileSync(`${home}/state/submissions`,'utf8') : '';
  await arm();
  if (phase === 'prepare') {
    enterAway();
    const result = await call({action:'prepare'});
    assert.equal(result.isError,true,`${signal} must veto reset preparation`);
    assert.equal(result.details.nonce,undefined,'away preparation must not create a nonce');
  } else if (phase === 'ready' || phase === 'ready-budget') {
    const n = (await call({action:'prepare'})).details.nonce;
    if (phase === 'ready-budget') writeFileSync(`${home}/state/budget-takeover`, signal);
    else enterAway();
    assert.equal((await call({action:'ready',nonce:n,stowComplete:true,onlyKeepingWatch:true,pendingQuestionsRecorded:true,stowReceipt:stowReceipt(),handoff:'Stowed in normal mode.'})).isError,true,`${signal} takeover must veto readiness`);
    assert.equal(timers.length,0,'away readiness must not schedule transport');
  } else {
    if (phase.startsWith('in-flight')) writeFileSync(`${home}/state/submit-pauses`, '');
    const n = await ready();
    if (phase.startsWith('in-flight')) {
      if (phase === 'in-flight-clean') writeFileSync(`${home}/state/submit-succeeds`,'');
      const submitting = runSubmit();
      await waitFile(`${home}/state/submit-started`);
      enterAway();
      if (phase === 'in-flight') input('Wai');
      writeFileSync(`${home}/state/submit-resume`, 'continue\n');
      await submitting;
      unlinkSync(`${home}/state/submit-pauses`);
      unlinkSync(`${home}/state/submit-started`);
      if (existsSync(`${home}/state/submit-succeeds`)) unlinkSync(`${home}/state/submit-succeeds`);
    } else {
      if (phase === 'input') await runSubmit();
      if (phase === 'command-budget') writeFileSync(`${home}/state/budget-takeover`, signal);
      else enterAway();
      if (phase === 'scheduled') await runSubmit();
      if (phase === 'input') input(frame(n));
      if (phase === 'command' || phase === 'command-budget') await commands.get('fm-reset').handler(n,ctx);
    }
    assert.equal(switches,0,`${signal} takeover at ${phase} must not switch`);
    assert.deepEqual(submitted,[],`${signal} takeover must not submit a registered command`);
    if (phase === 'scheduled') assert.equal(existsSync(`${home}/state/submissions`) ? readFileSync(`${home}/state/submissions`,'utf8') : '',beforeSubmissions,'away scheduler must not start transport');
    if (phase === 'in-flight') assert.equal(editor,'Wai','away cancellation must preserve the draft');
    assert.equal(recoveries().length,1,`${signal} cancellation must trigger one supervision continuation`);
    assert.equal(recoveries()[0].session,'old','away continuation must stay in the original session');
    for (const t of timers.filter(x=>x.ms===30000)) await t.fn();
    await commands.get('fm-reset').handler(n,ctx);
    assert.equal(recoveries().length,1,'late deadline and command must not duplicate away continuation');
  }
  unlinkSync(presence);
  if (existsSync(`${home}/state/budget-takeover`)) unlinkSync(`${home}/state/budget-takeover`);
} else if (scenario === 'retired-recovery') {
  await arm();
  await ready();
  const env = { ...process.env, OMPCODE: '1', PI_SESSION_ID: session, PI_TOOL_CALL_ID: 'intervening-arm' };
  const replaced = spawnSync(`${home}/bin/fm-watch-arm.sh`, ['--transition', 'work-pending', '--reason', 'intervening work'], { env, encoding: 'utf8' });
  assert.equal(replaced.status, 0, replaced.stderr);
  input('Wai');
  await runSubmit();
  assert.equal(recoveries().length, 1, 'retired recovery still queues supervision continuation');
  assert.ok(errors.some(x => x.text.includes('recovery declaration could not be saved')), 'retired recovery warning must reach the native visible UI');
  const resumed = spawnSync(`${home}/bin/fm-watch-arm.sh`, [], { env: { ...env, PI_TOOL_CALL_ID: 'after-retired-recovery' }, encoding: 'utf8' });
  assert.equal(resumed.status, 0, resumed.stderr);
  assert.match(resumed.stderr, /WARNING/, 'old callback cannot silently grant recovery for the successor');
  const verdict = JSON.parse(readFileSync(`${home}/state/.omp-watch-transitions.log`, 'utf8').trim().split('\n').at(-1));
  assert.equal(verdict.observed, 'unknown');
} else if (scenario === 'normal-seed') {
  await arm();
  const n = await ready();
  await commands.get('fm-reset').handler(n,ctx);
  const starts = messages.filter(x=>x.message.customType==='firstmate-reset-start' && x.options.triggerTurn);
  assert.equal(starts.length,1,'reset must send one replacement startup');
  const seed = starts[0].message.content;
  assert.match(seed,/^\u2063FIRSTMATE_OP: v1 session-start:/,'replacement startup must remain internal operational input');
  assert.match(seed,/bin\/fm-session-start\.sh/,'startup must run the complete startup procedure');
  for (const t of timers) await t.fn();
  await commands.get('fm-reset').handler(n,ctx);
  assert.equal(messages.filter(x=>x.options?.triggerTurn).length,1,'successful startup must have exactly one continuation after late callbacks');
  assert.deepEqual(errors, [], 'successful reset must not report a failure');
} else if (scenario === 'unquoted-arm') {
  await arm({command:'[ -f config/x-mode.env ] && . config/x-mode.env; exec bin/fm-watch-arm.sh'});
  jobs = {running:[{id:'watcher',type:'bash',command:'[ -f config/x-mode.env ] && . config/x-mode.env; exec bin/fm-watch-arm.sh'}],recent:[],delivery:{queued:0,delivering:false,pendingJobIds:[]}};
  await ready();
} else if (scenario === 'arm-gate') {
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
  await arm({command:'printf fake-status',receipt:false});
  assert.equal((await call({action:'prepare'})).isError, true, 'status from a different command must not unlock reset');
  for (const provenance of [{receipt:false},{receiptSession:'previous-session'},{receiptCall:'other-call'},{outputStatus:'unrelated result'},{nativeState:'completed'},{nativeError:true}]) {
    await emit('session_start');
    await arm(provenance);
    assert.equal((await call({action:'prepare'})).isError,true,'unrelated or historical arm result must not unlock reset');
  }
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
    if (scenario === 'veto-foreign-job') jobs = {running:[{id:'unrelated-job',command:'sleep 20'}],recent:[],delivery:{queued:0,delivering:false,pendingJobIds:[]}};
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
for (const { message } of messages.filter(x => /^firstmate-reset-(start|recovery)$/.test(x.message.customType))) {
  assertOperational(message);
}
console.log(`ok - reset regression ${scenario}`);
