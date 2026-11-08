import { appendFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import primary from './.omp/extensions/fm-primary-omp.ts';

export default function (pi: any) {
  const home = process.env.FM_HOME!;
  const root = process.cwd();
  const log = (value: unknown) => appendFileSync(`${home}/events.jsonl`, JSON.stringify(value) + '\n');
  let tool: any;
  pi.on('session_start', (_event: any, ctx: any) => {
    const locked = spawnSync(`${root}/bin/fm-lock.sh`, {env:{...process.env,OMPCODE:'1'}});
    log({kind:'start',session:ctx.sessionManager.getSessionId(),lock:locked.status});
  });
  primary(new Proxy(pi, { get(target, key) {
    if (key === 'registerTool') return (t: any) => { tool = t; pi.registerTool(t); };
    return Reflect.get(target, key);
  }}));
  let oldNonce = '';
  pi.registerCommand('fm-probe', {
    handler: async (action: string, ctx: any) => {
      const call = (p: unknown) => tool.execute('live-probe', p, undefined, undefined, ctx);
      const source = ctx.sessionManager.getSessionId();
      if (action === 'inspect') {
        log({kind:'inspect',session:source,jobs:ctx.getAsyncJobSnapshot()});
        return;
      }
      if (action === 'draft') {
        ctx.ui.setEditorText('half typed');
        const refused = await call({action:'prepare'});
        log({kind:'draft',error:refused.isError,session:source});
        return;
      }
      if (action === 'input') {
        const refused = await call({action:'ready',nonce:oldNonce,stowComplete:true,onlyKeepingWatch:true,handoff:'must not reset'});
        log({kind:'input',error:refused.isError,session:source});
        return;
      }
      const prepared = await call({action:'prepare'});
      if (prepared.isError) { log({kind:'failed-prepare',prepared}); return; }
      const nonce = prepared.details.nonce;
      if (action === 'failed') {
        const refused = await call({action:'ready',nonce,stowComplete:false});
        log({kind:'failed-stow',error:refused.isError,session:source});
        return;
      }
      // Empty fixture memories have no findings to route; perform the real
      // accounting and complete reads before attesting the fixture stow pass.
      const before = spawnSync(`${root}/bin/fm-startup-memory-budget.sh`, ['report'], {encoding:'utf8'});
      for (const name of ['captain.md','captain-shared.md','learnings.md']) readFileSync(`${home}/data/${name}`);
      const after = spawnSync(`${root}/bin/fm-startup-memory-budget.sh`, ['report'], {encoding:'utf8'});
      if (before.status || after.status || !after.stdout.includes('budget_status=within-budget')) throw new Error('fixture stow failed');
      const ready = await call({action:'ready',nonce,stowComplete:true,onlyKeepingWatch:true,
        handoff:'Open threads: data/backlog.md. Already reported: fixture dispatch answered. Next: startup, handle durable wakes, arm one cycle. Stow: empty memories unchanged, no exceptions.'});
      log({kind:'ready',error:ready.isError ?? false,session:source,nonce,before:before.stdout,after:after.stdout});
      oldNonce = nonce;
      if (action === 'success') {
        const appended = spawnSync('bash', ['-c', '. "$1/bin/fm-wake-lib.sh"; fm_wake_append heartbeat reset-proof "heartbeat: RESET_WAKE_PRESERVED"', '_', root]);
        if (appended.status !== 0) throw new Error('could not enqueue the live proof wake');
        pi.sendMessage({customType:'reset-live-finish',display:false,content:'The reset readiness attestation is complete. Reply with just a dot, with no tools. Let the extension finish this turn.'}, {triggerTurn:true});
      }
    },
  });
  pi.on('session_switch', (_event: any, ctx: any) => log({kind:'switch',session:ctx.sessionManager.getSessionId()}));
  pi.on('tool_call', (event: any) => {
    if (event.toolName === 'bash' && /bin\/fm-session-start\.sh/.test(event.input.command ?? '')) log({kind:'startup'});
  });
  pi.on('tool_result', (event: any) => {
    if (event.toolName === 'bash' && event.content?.some((c:any) => c.text?.includes('RESET_WAKE_PRESERVED'))) log({kind:'wake-drained'});
  });
}
