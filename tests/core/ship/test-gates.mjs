// Owns the tests of the CI gates (core/ship/gates.mjs, scripts/check-*.mjs): acceptance lines of lane L4 row "CI gates".
// Called by tests/core/ship/test-ship.mjs. Throwaway git repos only.
// @ts-check
import fs from 'node:fs'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { woTitleGate, generatedGate, decisionGate, globToRegex, matchAny, readPullRequest, loadGates } from '../../../core/ship/gates.mjs';
import { tempDir, originWithClone, commit } from './lib.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const pr = (over = {}) => ({ title: 'WO-2001: an example change', body: '', author: 'example-owner', headRef: 'wo/2001-example', ...over });

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
export function run(check) {
  // ---- globs
  check('gates: ** crosses folders and * stays in one', globToRegex('pass-app/public/**').test('pass-app/public/a/b.js') && !globToRegex('kitchen/*.md').test('kitchen/x/MAP.md') && globToRegex('kitchen/*.md').test('kitchen/MAP.md'));
  check('gates: a glob matches Windows separators too', matchAny('kitchen\\MAP.md', ['kitchen/MAP.md']));

  // ---- WO id in the PR title
  check('gates: WO title passes WO-2001: and WO-UPG-L4-1:', woTitleGate(pr()).status === 'pass' && woTitleGate(pr({ title: 'WO-UPG-L4-1: x' })).status === 'pass');
  check('gates: WO title passes an old Yard id (J312: x)', woTitleGate(pr({ title: 'J312: x' })).status === 'pass');
  for (const t of ['City G4: the City', 'wo-12: lower case', 'WO-12 no colon', 'x WO-12: not at the start']) {
    check(`gates: WO title fails "${t}"`, woTitleGate(pr({ title: t })).status === 'fail');
  }
  check('gates: WO title skips dependabot', woTitleGate(pr({ title: 'Bump x', author: 'dependabot[bot]' })).status === 'skip');
  check('gates: WO title skips a push (no PR)', woTitleGate(null).status === 'skip');

  // ---- no generated files
  check('gates: generated fails a PR that changes kitchen/MAP.md, naming it', (() => { const v = generatedGate(['a.txt', 'kitchen/MAP.md'], pr()); return v.status === 'fail' && v.lines.includes('- kitchen/MAP.md'); })());
  check('gates: generated passes a PR without generated files', generatedGate(['a.txt'], pr()).status === 'pass');
  check("gates: generated skips the docs step's own branch (ship/docs-*)", generatedGate(['kitchen/MAP.md'], pr({ headRef: 'ship/docs-map' })).status === 'skip');
  check('gates: the generated list comes from core/ship/gates.json', loadGates().generated.paths.includes('kitchen/MAP.md'));

  // ---- decision gate
  check('gates: decision fails Board-look files with no D-<n>', decisionGate(['pass-app/public/city.js'], pr()).status === 'fail');
  check('gates: decision passes Board-look files with D-7 in the body', decisionGate(['pass-app/public/city.js'], pr({ body: 'Answers D-7 (variant B).' })).status === 'pass');
  check('gates: decision passes a PR that does not touch the Board look', decisionGate(['core/ship/x.mjs', 'pass-app/server.mjs'], pr()).status === 'pass');
  check('gates: "D-7x" or "AD-7" is not a decision id', decisionGate(['pass-app/public/app.css'], pr({ body: 'AD-7 and D-7x' })).status === 'fail');

  // ---- the event file (GITHUB_EVENT_PATH)
  const dir = tempDir('gates');
  const evFile = path.join(dir, 'event.json');
  fs.writeFileSync(evFile, JSON.stringify({ pull_request: { title: 'WO-2001: x', body: null, user: { login: 'example-owner' }, head: { ref: 'wo/2001-x' } } }));
  const read = readPullRequest(evFile);
  check('gates: a pull_request event file is read (title, empty body, author, head)', read && read.title === 'WO-2001: x' && read.body === '' && read.author === 'example-owner' && read.headRef === 'wo/2001-x');
  const pushFile = path.join(dir, 'push.json');
  fs.writeFileSync(pushFile, JSON.stringify({ ref: 'refs/heads/main' }));
  check('gates: a push event file is not a PR', readPullRequest(pushFile) === null && readPullRequest(undefined) === null);

  // ---- acceptance: each gate is report-only with a step summary; enforce is a separate switch
  const { clone } = originWithClone();
  commit(clone, { 'kitchen/MAP.md': '# map\n', 'pass-app/public/city.js': '// x\n' }, 'touch generated and art');
  const summary = path.join(dir, 'summary.md');
  const env = { ...process.env, GITHUB_STEP_SUMMARY: summary, GITHUB_EVENT_PATH: evFile, GATE_MODE: '' };
  delete env.GATE_MODE;
  const cli = (script, args) => spawnSync(process.execPath, [path.join(repo, 'scripts', script), '--root', clone, '--base', 'HEAD^1', ...args], { cwd: clone, encoding: 'utf8', timeout: 20000, env });
  for (const script of ['check-wo-title.mjs', 'check-generated.mjs', 'check-decision-gate.mjs']) {
    const bad = script === 'check-wo-title.mjs' ? ['--title', 'no id here'] : [];
    const rep = cli(script, bad);
    check(`gates: ${script} fails report-only with exit 0`, rep.status === 0 && /FAIL \(report only\)/.test(rep.stdout), rep.stdout + rep.stderr);
    const enf = cli(script, [...bad, '--mode', 'enforce']);
    check(`gates: ${script} fails with exit 1 in enforce mode`, enf.status === 1 && /: FAIL$/m.test(enf.stdout), enf.stdout + enf.stderr);
  }
  const text = fs.existsSync(summary) ? fs.readFileSync(summary, 'utf8') : '';
  check('gates: every gate writes its verdict to the step summary', ['WO id in the PR title', 'no generated files', 'decision gate (Board look)'].every((n) => text.includes(`### Gate ${n}: FAIL`)) && text.includes('- kitchen/MAP.md'), text.slice(0, 400));
  const usage = cli('check-generated.mjs', ['--mode', 'loud']);
  check('gates: a wrong --mode is a usage error (exit 2)', usage.status === 2, usage.stdout);
  const broken = cli('check-generated.mjs', ['--base', 'no-such-ref']);
  check('gates: a gate that cannot run says so and exits 0 in report mode', broken.status === 0 && /could not run/.test(broken.stdout), broken.stdout);
  const brokenEnf = cli('check-generated.mjs', ['--base', 'no-such-ref', '--mode', 'enforce']);
  check('gates: a gate that cannot run exits 2 in enforce mode', brokenEnf.status === 2, brokenEnf.stdout);

  // ---- ci.yml wires each gate with its own one-line switch, report by default, and keeps the L0 contracts step
  const ci = fs.readFileSync(path.join(repo, '.github', 'workflows', 'ci.yml'), 'utf8');
  for (const sw of ['GATE_WO_TITLE', 'GATE_GENERATED', 'GATE_DECISION', 'GATE_NAMES', 'GATE_VALE']) {
    check(`gates: ci.yml has the one-line switch ${sw}: report`, new RegExp(`^\\s+${sw}: report\\b`, 'm').test(ci));
  }
  check('gates: ci.yml runs the three gate scripts', ['check-wo-title.mjs', 'check-generated.mjs', 'check-decision-gate.mjs'].every((s) => ci.includes(`scripts/${s}`)));
  check('gates: ci.yml keeps the L0 "Contracts (core/contracts" step', ci.includes('name: Contracts (core/contracts'));
  check('gates: ci.yml runs the ship suite', ci.includes('tests/Test-Ship.ps1'));
  check('gates: ci.yml node --checks core/ and runs the lanes\' suites from gates.json coreSuites', ci.includes('name: Core (node --check core/**/*.mjs') && ci.includes('.coreSuites.paths') && loadGates().coreSuites.paths.includes('tests/Test-CoreLedger.ps1'));
  const uses = [...ci.matchAll(/uses:\s*(\S+)/g)].map((m) => m[1]);
  check('gates: every action in ci.yml is pinned by a 40-hex commit sha', uses.length > 0 && uses.every((u) => /@[0-9a-f]{40}$/.test(u)), uses.join(', '));
}
