// Owns the tests of the docs step (core/ship/docs.mjs): acceptance lines of lane L4 row "docs station".
// Called by tests/core/ship/test-ship.mjs. Throwaway git repos only; the names guard runs for real when pwsh is on PATH.
// @ts-check
import fs from 'node:fs'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { checkDocs, newNamesOf, docsDoneEvent, runNamesGuard, rebuildMap } from '../../../core/ship/docs.mjs';
import { validate } from '../../../core/contracts/validate.mjs';
import { originWithClone, commit, g } from './lib.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const NOTE = (extra = '') => `# WO-2001: an example\n\n## Effects\n- L1 person: x\n- L2 business: x\n- L3 MSP: x\n- L4 community: x\n\n## New names\n- **Sunrise**: the example name\n${extra}`;
const GLOSSARY = '# Glossary\n| New | What |\n|---|---|\n| **Sunrise** | an example |\n';
const clean = () => ({ code: 0, out: 'Names: 0 found' });
const names = (r) => r.failures.map((f) => f.name).join(',');

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
export function run(check) {
  const { clone } = originWithClone();
  const root = clone;
  const write = (rel, text) => { const f = path.join(root, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); };
  const rm = (rel) => fs.rmSync(path.join(root, rel), { force: true });

  // ---- acceptance: a missing change note is a named failure
  const r0 = checkDocs({ root, wo: 'WO-2001' });
  check('docs: a missing change note fails as change-note-missing', !r0.ok && names(r0) === 'change-note-missing' && r0.dod['change-note'] === 'no', names(r0));
  write('docs/changes/WO-2001.md', '# WO-2001\n\nOnly L1 and L2.\n\n## New names\n- none\n');
  const r1 = checkDocs({ root, wo: 'WO-2001' });
  check('docs: a change note without the L3 and L4 effects fails as change-note-no-effects', names(r1) === 'change-note-no-effects' && /L3, L4/.test(r1.failures[0].detail), names(r1));
  write('docs/changes/WO-2001.md', '# WO-2001\n\nL1 L2 L3 L4.\n');
  const r2 = checkDocs({ root, wo: 'WO-2001' });
  check('docs: a change note with no "New names" section fails as new-names-unlisted', names(r2) === 'new-names-unlisted', names(r2));

  // ---- acceptance: a missing glossary entry is a named failure
  write('docs/changes/WO-2001.md', NOTE());
  write('docs/GLOSSARY.md', '# Glossary\n');
  const r3 = checkDocs({ root, wo: 'WO-2001' });
  check('docs: a new name missing from docs/GLOSSARY.md fails as glossary-missing, naming it', names(r3) === 'glossary-missing' && r3.failures[0].detail.includes('"Sunrise"') && r3.dod.glossary === 'no', names(r3));
  write('docs/GLOSSARY.md', GLOSSARY);
  const r4 = checkDocs({ root, wo: 'WO-2001', base: 'HEAD', names: clean });
  check('docs: a full change note, its name in the glossary and a clean names guard pass', r4.ok && r4.dod['change-note'] === 'yes' && r4.dod.glossary === 'yes' && r4.dod.names === 'yes', names(r4));
  write('docs/changes/WO-2001.md', NOTE().replace('- **Sunrise**: the example name', '- none'));
  const r5 = checkDocs({ root, wo: 'WO-2001' });
  check('docs: "New names: - none" passes with glossary n/a', r5.ok && r5.dod.glossary === 'n/a', names(r5));
  check('docs: new names are read from bold or plain bullets, up to the next heading', JSON.stringify(newNamesOf('## New names\n- **A b**: x\n- C (code: c)\n- none\n## Next\n- **D**\n')) === '["A b","C"]');

  // ---- acceptance: a names hit is a named failure
  const hit = checkDocs({ root, wo: 'WO-2001', base: 'HEAD', names: () => ({ code: 1, out: 'FOUND: docs/x.md:3 "sous chef"\nNames: 1 found' }) });
  check('docs: a names guard hit fails as names-hit, with the FOUND line', names(hit) === 'names-hit' && hit.failures[0].detail.includes('docs/x.md:3') && hit.dod.names === 'no', names(hit));
  const err = checkDocs({ root, wo: 'WO-2001', base: 'HEAD', names: () => ({ code: 2, out: 'names: folder not found' }) });
  check('docs: a names guard that cannot run fails as names-check-error, never as a pass', names(err) === 'names-check-error', names(err));
  check('docs: a non-WO id is refused', (() => { try { checkDocs({ root, wo: 'J2001' }); return false; } catch { return true; } })());

  // the real names guard: copy scripts/check-names.ps1 and its lists into the throwaway repo, add an old word, run it
  const pwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8', timeout: 30000 });
  if (pwsh.status === 0) {
    for (const f of ['check-names.ps1', 'names-allow.json', 'names-baseline.json']) write(`scripts/${f}`, fs.readFileSync(path.join(repo, 'scripts', f), 'utf8'));
    commit(root, {}, 'docs and the names guard');
    const base = g(root, ['rev-parse', 'HEAD']);
    commit(root, { 'docs/example.md': '# Example\n\nThe sous chef plans the day.\n' }, 'an old word in prose');
    const real = checkDocs({ root, wo: 'WO-2001', base });
    check('docs: the real names guard (check-names.ps1 -Enforce) turns an added old word into names-hit', names(real).includes('names-hit') && /sous chef/i.test(real.failures.find((f) => f.name === 'names-hit')?.detail || ''), JSON.stringify(real.failures));
    const none = runNamesGuard(root, 'HEAD');
    check('docs: the real names guard passes when nothing was added', none.code === 0, none.out.slice(-200));
    // MAP.md rebuilt after the merge (scripts/make-map.ps1), never committed by the step
    for (const f of ['make-map.ps1', 'standards-lib.ps1']) write(`scripts/${f}`, fs.readFileSync(path.join(repo, 'scripts', f), 'utf8'));
    write('kitchen/example.ps1', '# Owns an example.\n# Called by nobody.\nfunction Get-Example { 1 }\n');
    commit(root, {}, 'map inputs');
    const m1 = rebuildMap(root);
    check('docs: the map rebuild writes kitchen/MAP.md and says it changed, without committing', m1.ok && m1.changed && fs.existsSync(path.join(root, 'kitchen', 'MAP.md')) && g(root, ['status', '--porcelain']).includes('kitchen/MAP.md'), m1.detail);
    commit(root, {}, 'map');
    const m2 = rebuildMap(root);
    check('docs: a second rebuild on the same code says MAP.md is current', m2.ok && !m2.changed, m2.detail);
  } else check('docs: pwsh is on PATH for the real names guard run', false, 'pwsh not found; the names-hit acceptance ran only with the stub');

  // ---- the docs.done event follows the contract; it is written only on a pass
  rm('docs/example.md');
  const ev = docsDoneEvent({ wo: 'WO-2001', dod: r4.dod, ok: true, seq: 20, at: '2030-01-07T10:00:00Z' });
  check('docs: the docs.done event passes the event contract', validate('event', ev).ok, validate('event', ev).errors.join('; '));
  check('docs: no docs.done event for a failed check', (() => { try { docsDoneEvent({ wo: 'WO-2001', dod: r3.dod, ok: false, seq: 21, at: '2030-01-07T10:00:00Z' }); return false; } catch { return true; } })());

  // ---- the command line
  const cli = spawnSync(process.execPath, [path.join(repo, 'core/ship/docs.mjs'), 'check', '--wo', 'WO-2002', '--root', root], { encoding: 'utf8', timeout: 20000 });
  check('docs: "check" prints each named failure and exits 1', cli.status === 1 && /FAIL: change-note-missing/.test(cli.stdout) && /Docs step WO-2002: 1 failure/.test(cli.stdout), cli.stdout);
  const usage = spawnSync(process.execPath, [path.join(repo, 'core/ship/docs.mjs'), 'check', '--wo', 'nope'], { encoding: 'utf8', timeout: 20000 });
  check('docs: a bad work order id is a usage error (exit 2)', usage.status === 2);
}
