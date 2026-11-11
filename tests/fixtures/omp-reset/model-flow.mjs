import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const [root, lab] = process.argv.slice(2);
const cases = process.env.FM_OMP_RESET_FLOW_CASE ? [process.env.FM_OMP_RESET_FLOW_CASE] : ['high','low','unavailable','away'];
for (const mode of cases) {
  const away = mode === 'away';
  const protocol = spawnSync(`${root}/bin/fm-supervision-instructions.sh`, ['--harness','omp','--afk',away ? '1' : '0'], {encoding:'utf8'});
  assert.equal(protocol.status, 0);
  const stow = readFileSync(`${root}/.agents/skills/stow/SKILL.md`,'utf8');
  const afk = away ? readFileSync(`${root}/.agents/skills/afk/SKILL.md`,'utf8') : '';
  const usage = mode === 'unavailable'
    ? 'Context usage is unavailable: ctx.getContextUsage() returned undefined for the session under test.'
    : `For the session under test, ctx.getContextUsage() reports ${JSON.stringify({tokens:mode === 'low' ? 39990 : 60000,contextWindow:100000,percent:mode === 'low' ? 39.99 : 60})}.`;
  const task = mode === 'away'
    ? 'Away mode is active. All wake handling is done and only keeping watch remains. Execute ONLY step 4 of the away skill handling list, and any owner that step explicitly references. Do not reconcile it with instructions it does not reference. If the step explicitly requires re-arming, return REARM. If its referenced owner selects reset preparation, return PREPARE_RESET. Return only the one operation.'
    : `You are handling ${mode === 'away' ? 'an internal away wake; away mode remains active' : 'an ordinary wake in normal mode'}. Wake handling is complete. Instructions have reached the workers, nothing waits on your next step, and only keeping watch remains. Execute step 4 of ${mode === 'away' ? '"Handle an internal away wake silently" in the away skill' : '"When the arm job completion arrives" in the protocol'} literally. Use other paragraphs only when that step explicitly references them, then follow that reference to its owner. Return exactly PREPARE_RESET or REARM as the next operation.`;
  writeFileSync(`${lab}/model-flow-${mode}.md`, `This is a bounded instruction-execution test, not a code review. Do not use tools or propose changes. ${task}\n\nScenario state:\nThis is an ordinary post-heartbeat continuation after completed startup and a successful supervision arm, not startup or reset recovery. One worker remains in flight. The last message has been answered, every unanswered question is durably recorded in the decision inbox, and no push, merge, cleanup or steer is half done. No reset has been prepared yet.\n\nScenario measurement:\n${usage}\n\nEmitted protocol:\n${protocol.stdout}\n\nReferenced stow skill:\n${stow}\n\nAway skill:\n${afk}`);
  const model = spawnSync(process.env.FM_OMP_RESET_EXECUTABLE ?? 'omp', ['--no-context-files','--no-rules','--no-skills','--no-extensions','--no-tools','--no-session','--no-title','--thinking','low','--model',process.env.FM_OMP_LIVE_MODEL??'anthropic/claude-sonnet-5-5','-p',`@model-flow-${mode}.md`], {cwd:lab,encoding:'utf8'});
  writeFileSync(`${lab}/model-flow-${mode}.out`, model.stdout + model.stderr);
  if (process.env.FM_OMP_RESET_FLOW_EVIDENCE) {
    writeFileSync(`${process.env.FM_OMP_RESET_FLOW_EVIDENCE}/${mode}.prompt.md`, readFileSync(`${lab}/model-flow-${mode}.md`));
    writeFileSync(`${process.env.FM_OMP_RESET_FLOW_EVIDENCE}/${mode}.out`, model.stdout + model.stderr);
  }
  assert.equal(model.status,0,model.stderr);
  const expected = mode === 'normal' || mode === 'high' ? 'PREPARE_RESET' : 'REARM';
  assert.match(model.stdout.trim(), new RegExp(`(?:^|\\n)${expected}\\s*$`), `${mode} flow selected ${model.stdout.trim()}`);
  console.log(`ok - model follows emitted ${mode} flow: ${expected}`);
}
