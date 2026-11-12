import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const [root, lab] = process.argv.slice(2);
mkdirSync(lab, {recursive:true});
const executable = `${lab}/model`;
writeFileSync(executable, '#!/usr/bin/env node\nprocess.stdout.write(process.env.FM_FLOW_RESPONSE);\n', {mode:0o700});
const cases = [
  ['unavailable', 'REARM\n\nContext usage is unavailable, so preparation must refuse.', true],
  ['low', 'REARM because usage is below the threshold.', true],
  ['high', 'PREPARE_RESET\nThe measured usage exceeds 40%.', true],
  ['away', 'REARM\nAway handling requires re-arming.', true],
  ['away', 'Step 4 refers to the stow skill. Away mode requires re-arming regardless of the high usage.\n\nREARM', true],
  ['high', 'REARM would skip the required stow here.\n\nPREPARE_RESET', true],
  ['low', 'PREPARE_RESET would be refused at this usage.\n\nREARM', true],
  ['high', 'PREPARE_RESET would be wrong here.\n\nREARM', false],
  ['unavailable', 'REARM would be wrong here.\n\nPREPARE_RESET', false],
  ['unavailable', 'REARM\nPREPARE_RESET', false],
  ['high', 'PREPARE_RESET\nREARM', false],
  ['unavailable', 'The instructions mention REARM', false],
  ['unavailable', 'REARMING', false],
];
for (const [index, [mode, response, accepted]] of cases.entries()) {
  const cwd = `${lab}/${index}`;
  mkdirSync(cwd);
  const result = spawnSync(process.execPath, [`${root}/tests/fixtures/omp-reset/model-flow.mjs`,root,cwd], {
    encoding:'utf8', env:{...process.env,FM_OMP_RESET_FLOW_CASE:mode,FM_OMP_RESET_EXECUTABLE:executable,
      FM_FLOW_RESPONSE:response,FM_OMP_RESET_FLOW_EVIDENCE:''},
  });
  assert.equal(result.status, accepted ? 0 : 1,
    `${mode}: selected operation must determine the verdict for ${JSON.stringify(response)}\n${result.stdout}${result.stderr}`);
  if (!accepted) assert.match(result.stderr, /AssertionError/, 'wrong decisions must fail the behavioral assertion');
  console.log(`ok - model-flow decision ${index}: ${accepted ? 'accepted' : 'rejected'}`);
}
