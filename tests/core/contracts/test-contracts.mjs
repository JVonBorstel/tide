// Owns the tests of the shared contracts (core/contracts): schemas, fixtures, the validator, the front matter format and the upgrade switches.
// Called by tests/Test-Contracts.ps1 (the Yard's tests Step, verify-all), the ci.yml contracts step, and by hand: node tests/core/contracts/test-contracts.mjs
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { validate, runFixtures, loadSchemas, contractNames, readDoc, localOnlyPaths, KNOWN_MAJORS } from '../../../core/contracts/validate.mjs';
import { publicErrors, toPublic, STRIPPED } from '../../../core/contracts/public.mjs';
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
  const wrong = [...schemas].filter(([f, s]) => s.$schema !== 'https://json-schema.org/draft/2020-12/schema' || s.$id !== `https://tide.example/contracts/v${KNOWN_MAJORS[0]}/${f}`).map(([f]) => f);
  check('schemas: all are JSON Schema 2020-12 with a versioned $id (contracts/v1/<file>)', !wrong.length, wrong.join(', '));
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
  check('validator: date-time takes RFC 3339 and refuses impossible dates', isDateTime('2030-01-07T09:00:00Z') && isDateTime('2030-01-07T09:00:00.5+09:00') && !isDateTime('2030-02-30T09:00:00Z') && !isDateTime('2030-01-07 09:00'));
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

// ---- review fixes: versions, CREED 6, relative paths, local-only values
const PERSISTED = ['event', 'decision', 'row', 'brief', 'report', 'activity', 'activity-result', 'upgrade'];
const fixture = (rel) => readDoc(path.join(fixtures, rel));
function testVersions() {
  const schemas = loadSchemas(dir);
  const missing = PERSISTED.filter((n) => { const s = schemas.get(`${n}.schema.json`); return !s.required.includes('v') || !s.properties.v; });
  check('versions: every persisted record (event, decision, row, brief, report, activity, result, upgrade) requires v', !missing.length, missing.join(', '));
  const ev = fixture('event/valid/step.done.json');
  check('versions: a newer minor of a known major is accepted', validate('event', { ...ev, v: '1.7' }).ok);
  const two = validate('event', { ...ev, v: '2.0' });
  check('versions: an unknown major is refused by name', !two.ok && two.errors.some((e) => e.startsWith('/v: version: major 2 is not known')), two.errors.join('; '));
  const readme = fs.readFileSync(path.join(dir, 'README.md'), 'utf8');
  check('versions: the README states the evolution rule (additive = minor, breaking = new major, readers accept known majors)', /additive/i.test(readme) && /new major/i.test(readme) && /known majors/i.test(readme));
}
function testCreed6() {
  const ev = fixture('event/valid/review.verdict.json');
  check('creed 6: a verdict by a verifier that is not the builder passes', validate('event', ev).ok);
  const same = validate('event', { ...ev, data: { ...ev.data, reviewer: ev.data.builder } });
  check('creed 6: reviewer = builder is refused', !same.ok && same.errors.some((e) => e.startsWith('/data/reviewer: creed6')), same.errors.join('; '));
  const item = fixture('api-work-item/valid/item.json');
  const nested = validate('api-work-item', { ...item, events: [...item.events, { ...ev, actor: ev.data.builder }] });
  check('creed 6: a verdict written by the builder is refused inside an API answer too', !nested.ok && nested.errors.some((e) => /^\/events\/\d+\/actor: creed6/.test(e)), nested.errors.join('; '));
}
function testRelPaths() {
  const row = fixture('row/valid/build.json');
  const ok = ['work/WO-1/BRIEF.md', 'mockups/a.png', 'wt/wo-1', 'a..b/c.md'];
  const refused = ['~/notes/x.md', '~someone/x.md', '/srv/x.md', '\\host\\share\\x.md', 'D:/x.md', 'D:\\x.md', 'file:///x.md', '../x.md', 'work/../../x.md', 'work\\..\\x.md', 'work/..'];
  const wrongOk = ok.filter((p) => !validate('row', { ...row, brief: p }).ok);
  const wrongBad = refused.filter((p) => validate('row', { ...row, brief: p }).ok);
  check('paths: relative paths pass; ~, absolute, drive, scheme and .. escapes are refused', !wrongOk.length && !wrongBad.length, `accepted: ${wrongBad.join(' ')}; refused: ${wrongOk.join(' ')}`);
}
function testLocalOnly() {
  const merged = fixture('event/valid/merged.json');
  const marked = [['event', merged, '/proof'], ['row', fixture('row/valid/closed.json'), '/proof'], ['activity', fixture('activity/valid/freshen.json'), '/args'],
    ['activity-result', fixture('activity-result/valid/ok.json'), '/out'], ['activity-result', fixture('activity-result/valid/ok.json'), '/proof']];
  const unmarked = marked.filter(([n, d, p]) => !localOnlyPaths(n, d).includes(p)).map(([n, , p]) => n + p);
  check('local-only: proof, out and args are marked x-local-only', !unmarked.length, unmarked.join(', '));
  const item = fixture('api-work-item/valid/item.json');
  check('local-only: marks are found inside nested records (an API answer)', localOnlyPaths('api-work-item', item).includes('/events/0/proof') && localOnlyPaths('api-work-item', item).includes('/row/proof'));
  const leaky = { ...merged, proof: 'D:\\private\\notes\\merge.txt and ~/notes/x' };
  const errs = publicErrors('event', leaky);
  check('local-only: the public path rejects a local path in proof', errs.length === 1 && errs[0].startsWith('/proof: local-only'), errs.join('; '));
  const act = { ...fixture('activity/valid/freshen.json'), args: { log: '/srv/private/run.log', list: ['ok', '\\\\host\\share\\x'] } };
  const pub = toPublic('activity', act);
  const clean = JSON.stringify(pub.doc);
  check('local-only: toPublic strips every local path (nested args too) and the record stays valid',
    pub.stripped.length === 2 && !clean.includes('/srv/') && !clean.includes('share') && clean.includes(STRIPPED) && validate('activity', pub.doc).ok && act.args.log === '/srv/private/run.log', JSON.stringify(pub));
  const url = { ...merged, proof: 'https://github.com/example-owner/example-repo/home/x and sha a1b2c3d' };
  check('local-only: a URL or a sha in proof is left as it is', !publicErrors('event', url).length && toPublic('event', url).doc.proof === url.proof);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tide-public-'));
  try {
    fs.writeFileSync(path.join(tmp, 'leaky.json'), JSON.stringify(leaky));
    const good = node(['core/contracts/public.mjs', 'event', 'core/contracts/fixtures/event/valid/merged.json']);
    const bad = node(['core/contracts/public.mjs', 'event', path.join(tmp, 'leaky.json')]);
    check('local-only: public.mjs exits 0 on a clean record and 1 on a leaky one', good.status === 0 && bad.status === 1, `${good.status}/${bad.status}: ${bad.stdout}`);
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

for (const t of [testSchemas, testFixtureCoverage, testSynthetic, testValidatorCli, testValidatorCore, testFrontMatter, testSwitches, testVersions, testCreed6, testRelPaths, testLocalOnly]) {
  try { t(); } catch (e) { check(`${t.name} ran without a crash`, false, e.stack.split('\n').slice(0, 3).join(' | ')); }
}
for (const r of results.filter((x) => !x.pass)) console.log(`FAIL: ${r.name}`);
const failed = results.filter((x) => !x.pass).length;
console.log(`Contracts tests: ${results.length - failed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
