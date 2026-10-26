// Owns the tests of the shared contracts (core/contracts): schemas, fixtures, the validator, the front matter format and the upgrade switches.
// Called by tests/Test-Contracts.ps1 (the Yard's tests Step, verify-all), the ci.yml contracts step, and by hand: node tests/core/contracts/test-contracts.mjs
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { validate, runFixtures, loadSchemas, contractNames, readDoc } from '../../../core/contracts/validate.mjs';
import { makeChecker, isDateTime } from '../../../core/contracts/jsonschema.mjs';
import { parseFrontMatter, formatFrontMatter } from '../../../core/contracts/frontmatter.mjs';
import { PIECES, switchOf, readSwitches } from '../../../core/contracts/upgrade.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const dir = path.join(repo, 'core', 'contracts');
const fixtures = path.join(dir, 'fixtures');
const results = [];
const check = (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });
const node = (args, cwd = repo) => spawnSync(process.execPath, args, { cwd, encoding: 'utf8', timeout: 20000 });
const listJson = (rel) => fs.readdirSync(path.join(fixtures, rel)).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, ''));
const enumOf = (file, pointer) => pointer.split('/').reduce((n, k) => n[k], JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'))).enum;

// ---- schemas: each schema validates its valid fixtures and rejects each invalid fixture with a named reason
function testSchemas() {
  const all = runFixtures(dir);
  const schemas = loadSchemas(dir);
  for (const name of contractNames(schemas)) {
    const valid = all.filter((r) => r.name.startsWith(`${name}/valid/`));
    const bad = valid.filter((r) => !r.pass);
    check(`schemas: ${name} accepts its ${valid.length} valid fixtures`, valid.length && !bad.length, bad.map((r) => `${r.name}: ${r.detail}`).join('; ') || 'none found');
    const invalid = all.filter((r) => r.name.startsWith(`${name}/invalid/`));
    check(`schemas: ${name} has invalid fixtures`, invalid.length > 0);
    for (const r of invalid) check(`schemas: ${r.name} is rejected with its named reason`, r.pass, r.detail);
  }
  const lint = (() => { try { makeChecker(schemas).lint(); return ''; } catch (e) { return e.message; } })();
  check('schemas: every keyword is one the validator checks and every $ref resolves', !lint, lint);
  const wrong = [...schemas].filter(([f, s]) => s.$schema !== 'https://json-schema.org/draft/2020-12/schema' || s.$id !== `https://tide.example/contracts/${f}`).map(([f]) => f);
  check('schemas: all are JSON Schema 2020-12 with an $id named after the file', !wrong.length, wrong.join(', '));
}

// ---- fixtures: one fixture per event kind (17), per decision kind (8), per stage (8); all synthetic
function testFixtureCoverage() {
  const cover = (what, kinds, have, n) => {
    const missing = kinds.filter((k) => !have.includes(k));
    check(`fixtures: one ${what} fixture per kind (${n})`, kinds.length === n && !missing.length, `kinds ${kinds.length}; missing ${missing.join(', ')}`);
  };
  cover('event', enumOf('event.schema.json', '$defs/kind'), listJson('event/valid'), 17);
  cover('decision', enumOf('common.schema.json', '$defs/decisionKind'), listJson('decision/valid'), 8);
  cover('row (stage)', enumOf('common.schema.json', '$defs/stage'), listJson('row/valid'), 8);
  for (const k of enumOf('event.schema.json', '$defs/kind')) {
    const doc = JSON.parse(fs.readFileSync(path.join(fixtures, 'event', 'valid', `${k}.json`), 'utf8'));
    if (doc.kind !== k) check(`fixtures: event/valid/${k}.json is a ${k} event`, false, `kind is ${doc.kind}`);
  }
}

const PRIVATE_SHAPES = [
  ['a user folder', /[A-Za-z]:[\\/]+Users[\\/]|\/home\/[a-z]|\/Users\/[a-z]/i],
  ['an email that is not example or noreply', /[\w.+-]+@(?!example\.(com|org|net)\b)(?!users\.noreply\.github\.com\b)[\w-]+\.[\w.-]+/i],
  ['a tailnet name', /\.ts\.net\b/i],
  ['a private or tailnet IP', /\b(10\.\d+|192\.168|172\.(1[6-9]|2\d|3[01])|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d+\.\d+\b/],
];
function testSynthetic() {
  const hits = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      const text = fs.readFileSync(p, 'utf8');
      for (const [what, re] of PRIVATE_SHAPES) if (re.test(text)) hits.push(`${path.relative(fixtures, p)}: ${what}`);
    }
  };
  walk(fixtures);
  check('fixtures: all synthetic (no user folder, real-looking email, tailnet name or private IP)', !hits.length, hits.join('; '));
}

// ---- validator: node core/contracts/validate.mjs exits 0 on fixtures and 1 on a broken one
function testValidatorCli() {
  const ok = node(['core/contracts/validate.mjs']);
  check('validator: validate.mjs exits 0 on the fixtures', ok.status === 0, `${ok.status}: ${(ok.stdout || '').trim().split('\n').pop()}`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tide-contracts-'));
  try {
    fs.cpSync(dir, tmp, { recursive: true });
    const f = path.join(tmp, 'fixtures', 'event', 'valid', 'merged.json');
    fs.writeFileSync(f, JSON.stringify({ ...JSON.parse(fs.readFileSync(f, 'utf8')), proof: null }));
    const broken = node([path.join(tmp, 'validate.mjs')], tmp);
    check('validator: validate.mjs exits 1 on a broken fixture and names it', broken.status === 1 && /FAIL: event\/valid\/merged\.json/.test(broken.stdout), `${broken.status}: ${broken.stdout}`);
    fs.writeFileSync(path.join(tmp, 'broken.json'), '{ not json');
    const bad = node(['core/contracts/validate.mjs', '--schema', 'report', 'core/contracts/fixtures/brief/valid/art-brief.json']);
    const unreadable = node(['core/contracts/validate.mjs', '--schema', 'event', path.join(tmp, 'broken.json')]);
    const usage = node(['core/contracts/validate.mjs', '--schema', 'nope', 'x.json']);
    check('validator: --schema exits 1 on an invalid file, 2 on an unreadable one and 2 on an unknown contract', bad.status === 1 && unreadable.status === 2 && usage.status === 2,
      `${bad.status}/${unreadable.status}/${usage.status}`);
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

function testValidatorCore() {
  const refused = (() => { try { makeChecker(new Map([['x.schema.json', { type: 'array', minContains: 1 }]])).check('x.schema.json', []); return false; } catch (e) { return /unsupported keyword "minContains"/.test(e.message); } })();
  check('validator: an unsupported keyword is refused, never skipped', refused);
  check('validator: date-time takes RFC 3339 and refuses impossible dates', isDateTime('2030-01-07T09:00:00Z') && isDateTime('2030-01-07T09:00:00.5-07:00') && !isDateTime('2030-02-30T09:00:00Z') && !isDateTime('2030-01-07 09:00'));
  const r = validate('event', { seq: 1 });
  check('validator: validate() returns readable reasons with the path', !r.ok && r.errors.includes('/at: required: is missing'), r.errors.join('; '));
}

// ---- front matter (brief and report): the line format, its errors and the round trip
function testFrontMatter() {
  const b = readDoc(path.join(fixtures, 'brief', 'valid', 'BRIEF.md'));
  check('front matter: BRIEF.md parses, comments dropped, depth read as a number', b.wo === 'WO-2005' && b.depth === 1 && validate('brief', b).ok, JSON.stringify(b));
  const r = readDoc(path.join(fixtures, 'report', 'valid', 'REPORT.md'));
  check('front matter: REPORT.md parses tests counts and check marks', r.tests.length === 2 && r.tests[0].passed === 53 && r.dod.glossary === 'n/a' && validate('report', r).ok, JSON.stringify(r));
  const cases = [
    ['no front matter', '# Goal\n', 'no front matter'],
    ['an unclosed block', '---\nwo: WO-1\n', 'not closed'],
    ['a repeated key', '---\nwo: WO-1\nwo: WO-2\n---\n', '"wo" appears twice'],
    ['a line that is not key: value', '---\nwo WO-1\n---\n', 'line 2 is not'],
    ['a bad tests line', '---\ntests: all green\n---\n', 'tests must be'],
    ['an unknown dod mark', '---\ndod: tests maybe\n---\n', 'dod must be'],
  ];
  for (const [what, text, want] of cases) {
    const p = parseFrontMatter(text);
    check(`front matter: ${what} gives a named error`, !p.ok && p.error.includes(want), p.error || 'parsed');
  }
  for (const f of ['brief/valid/art-brief.json', 'report/valid/pushed.json', 'report/valid/blocked.json']) {
    const doc = JSON.parse(fs.readFileSync(path.join(fixtures, f), 'utf8'));
    const back = parseFrontMatter(formatFrontMatter(doc));
    check(`front matter: ${f} survives format then parse`, back.ok && JSON.stringify(back.data) === JSON.stringify(doc), back.error || JSON.stringify(back.data));
  }
}

// ---- switch block: kitchen.json "upgrade" is valid and all "old"
function testSwitches() {
  const cfg = JSON.parse(fs.readFileSync(path.join(repo, 'kitchen', 'kitchen.json'), 'utf8'));
  const v = validate('upgrade', cfg.upgrade);
  check('switch block: kitchen.json "upgrade" matches upgrade.schema.json', v.ok, v.errors.join('; '));
  const raw = (p) => p.split('.').reduce((n, k) => (n && typeof n === 'object' ? n[k] : undefined), cfg.upgrade);
  const notOld = PIECES.filter((p) => raw(p) !== 'old');
  check('switch block: every piece is "old" in the repo copy', !notOld.length, notOld.join(', '));
  const want = ['ledger', 'engine.adopted', 'engine.improve', 'crews', 'ship.gates', 'ship.queue', 'board.work', 'continuity.boot'];
  check('switch block: the pieces are exactly the 8 build-way 4.3 names', JSON.stringify([...PIECES].sort()) === JSON.stringify([...want].sort()), PIECES.join(', '));
  const fallback = switchOf({}, 'ledger') === 'old' && switchOf({ upgrade: { engine: {} } }, 'engine.adopted') === 'old' && switchOf({ upgrade: { ledger: 'on' } }, 'ledger') === 'old' && switchOf({ upgrade: { ledger: 'new' } }, 'ledger') === 'new';
  const unknown = (() => { try { switchOf(cfg, 'rocket'); return false; } catch (e) { return /unknown upgrade piece/.test(e.message); } })();
  check('switch block: a missing block, missing piece or unknown value reads old; an unknown piece name throws', fallback && unknown);
  const none = readSwitches(path.join(os.tmpdir(), `tide-no-such-${process.pid}.json`));
  check('switch block: an unreadable kitchen.json reads all old, with the reason', none.error && Object.values(none.switches).every((s) => s === 'old'), JSON.stringify(none));
}

for (const t of [testSchemas, testFixtureCoverage, testSynthetic, testValidatorCli, testValidatorCore, testFrontMatter, testSwitches]) {
  try { t(); } catch (e) { check(`${t.name} ran without a crash`, false, e.stack.split('\n').slice(0, 3).join(' | ')); }
}
for (const r of results.filter((x) => !x.pass)) console.log(`FAIL: ${r.name}`);
const failed = results.filter((x) => !x.pass).length;
console.log(`Contracts tests: ${results.length - failed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
