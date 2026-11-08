import { appendFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import primary from './.omp/extensions/fm-primary-omp.ts';

export default function (pi: any) {
  const home = process.env.FM_HOME!;
  const root = process.cwd();
  const log = (value: unknown) => appendFileSync(`${home}/events.jsonl`, JSON.stringify(value) + '\n');
  let session = '';
  let currentContext: any;
  pi.on('session_start', (_event: any, ctx: any) => {
    const locked = spawnSync(`${root}/bin/fm-lock.sh`, {env:{...process.env,OMPCODE:'1'}});
    session = ctx.sessionManager.getSessionId();
    currentContext = ctx;
    log({kind:'start',session,lock:locked.status});
  });
  primary(new Proxy(pi, {get(target, key) {
    if (key === 'sendMessage') return (message: any, options: any) => {
      if (message.customType === 'firstmate-reset-recovery') log({kind:'recovery',session,editor:currentContext.ui.getEditorText(),jobs:currentContext.getAsyncJobSnapshot()});
      return pi.sendMessage(message, options);
    };
    return Reflect.get(target,key);
  }}));
  pi.registerCommand('fm-probe', {
    handler: async (action: string, ctx: any) => {
      if (action === 'inspect') {
        log({kind:'inspect',session:ctx.sessionManager.getSessionId(),jobs:ctx.getAsyncJobSnapshot(),editor:ctx.ui.getEditorText()});
        return;
      }
      if (action === 'race') writeFileSync(`${home}/state/fixture-draft-race`, '');
      const protocol = spawnSync(`${root}/bin/fm-supervision-instructions.sh`, ['--harness','omp'], {encoding:'utf8'}).stdout;
      const content = action === 'startup'
        ? 'This is an isolated native supervision fixture. Run bin/fm-session-start.sh exactly once now, read its complete digest and required STOP files, then follow its startup supervision protocol and verify the arm status. Do no project work. The fixture dispatch has already been answered. End the turn after the successful initial arm; this is startup, not a watching-only transition.'
        : `The fixture dispatch has been answered and no further action remains except keeping watch. No questions, changes or half-done work remain. We are executing ordinary-wake continuation step 4 below; apply that step as written with the watching-only condition true. Follow any procedure it returns, and do not invent instructions.\n\n${protocol}`;
      pi.sendMessage({customType:'reset-model-fixture',display:false,content},{triggerTurn:true});
    },
  });
  pi.on('session_before_switch', () => {
    const appended = spawnSync('bash', ['-c', '. "$1/bin/fm-wake-lib.sh"; fm_wake_append heartbeat reset-proof "heartbeat: RESET_WAKE_PRESERVED"', '_', root]);
    if (appended.status !== 0) throw new Error('could not enqueue proof wake');
  });
  pi.on('session_switch', (_event: any, ctx: any) => {
    session = ctx.sessionManager.getSessionId();
    currentContext = ctx;
    log({kind:'switch',session});
  });
  pi.on('input', (event: any) => log({kind:'input',text:event.text,session}));
  pi.on('tool_call', (event: any) => {
    if (event.toolName === 'firstmate_watch_reset') log({kind:'reset-tool',session,input:event.input});
    if (event.toolName === 'bash') {
      log({kind:'bash',session,input:event.input});
      if (/bin\/fm-session-start\.sh/.test(event.input.command ?? '')) log({kind:'startup',session});
    }
    if (event.toolName === 'read') log({kind:'read',session,input:event.input});
  });
  pi.on('tool_result', (event: any) => {
    const text = event.content?.filter((c:any)=>c.type==='text').map((c:any)=>c.text).join('\n') ?? '';
    if (event.toolName === 'read' && /^watcher: (started|attached)/m.test(text)) log({kind:'armed',session,input:event.input,status:text.match(/^watcher:.*$/m)?.[0]});
    if (event.toolName === 'firstmate_watch_reset') {
      log({kind:'reset-result',session,input:event.input,error:event.isError??false});

    }
    if (text.includes('RESET_WAKE_PRESERVED')) log({kind:'wake-drained',session});
  });
}
