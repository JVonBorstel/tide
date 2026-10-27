// Owns the tests of the public glossary (docs/GLOSSARY.md), its pointer in AGENTS.md and the Vale vocabulary (.vale/): lane L4 row "glossary".
// Called by tests/core/ship/test-ship.mjs. Reads repo files only. (Vale itself runs in CI: the ci.yml "gates" job.)
// @ts-check
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const read = (rel) => fs.readFileSync(path.join(repo, rel), 'utf8');

// The shapes of private data that never reach the public copy. Other projects' names and this PC's live values are checked by the
// Office's public-tide scan, run by hand on every diff (it reads the live values at run time; they are never written here).
const PRIVATE = [
  ['a user folder', /[A-Za-z]:[\\/]+Users[\\/]|\/home\/[a-z]|\/Users\/[a-z]/i],
  ['an email that is not noreply or example', /[\w.+-]+@(?!example\.(com|org|net)\b)(?!users\.noreply\.github\.com\b)[\w-]+\.[\w.-]+/i],
  ['a tailnet name', /\.ts\.net\b/i],
  ['a private or tailnet IP', /\b(10\.\d+|192\.168|172\.(1[6-9]|2\d|3[01])|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d+\.\d+\b/],
];

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
export function run(check) {
  const g = read('docs/GLOSSARY.md');
  for (const [what, rx] of PRIVATE) {
    const hits = g.split('\n').map((l, i) => (rx.test(l) ? i + 1 : 0)).filter(Boolean);
    check(`glossary: privacy scan finds no ${what}`, hits.length === 0, `lines ${hits.join(', ')}`);
  }
  const agents = read('AGENTS.md').split(/\r?\n/);
  check('glossary: AGENTS.md line 3 points at docs/GLOSSARY.md', /`docs\/GLOSSARY\.md` is the only naming source/.test(agents[2] || ''), agents[2]);
  check('glossary: AGENTS.md no longer points at the private glossary', !agents.join('\n').includes('naming/GLOSSARY.md'));

  for (const n of ['Flag', 'Handover queue', 'Resurvey', 'Docs step', 'Change note', 'Gate', 'Decision gate', 'Generated file']) {
    check(`glossary: the ship path's name "${n}" is defined`, new RegExp(`\\| \\*\\*${n}\\*\\*`).test(g));
  }
  const vocab = '.vale/styles/config/vocabularies/Tide';
  const ini = read('.vale/vale.ini');
  check('glossary: vale.ini uses the Tide vocabulary and its folder exists', /^Vocab = Tide$/m.test(ini) && /^StylesPath = styles$/m.test(ini) && fs.existsSync(path.join(repo, vocab, 'accept.txt')) && fs.existsSync(path.join(repo, vocab, 'reject.txt')));
  check('glossary: vale.ini keeps every rule at warning or off (Vale exits 0; the warnings are the report)', !/=\s*error\b/i.test(ini) && /Vale\.Spelling = NO/.test(ini));
  const words = (f) => read(`${vocab}/${f}`).split('\n').map((s) => s.trim()).filter(Boolean);
  const notIn = words('accept.txt').filter((w) => !['GitHub', 'PowerShell', 'Tailscale', 'Dependabot', 'Vale'].includes(w) && !g.includes(`**${w}**`));
  check('glossary: every Tide name in accept.txt is a bold name in the glossary', notIn.length === 0, notIn.join(', '));
  const rejected = words('reject.txt').map((w) => w.replace(/^\(\?i\)/, ''));
  const notOld = rejected.filter((w) => !g.toLowerCase().includes(w.toLowerCase()));
  check('glossary: every word in reject.txt is an old word the glossary lists', notOld.length === 0, notOld.join(', '));
}
