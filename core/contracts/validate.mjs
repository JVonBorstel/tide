// Owns the shared contracts' loader, cross-field rules and command line: check any contract object, or every fixture in fixtures/.
// Called by lanes L1-L6 (import { validate }), tests/core/contracts/test-contracts.mjs, the ci.yml contracts step, and by hand (usage below).
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath, pathToFileURL } from 'node:url';
import { makeChecker, formatError } from './jsonschema.mjs';
import { parseFrontMatter } from './frontmatter.mjs';

export const here = path.dirname(fileURLToPath(import.meta.url));
const USAGE = `usage: node core/contracts/validate.mjs                      check every fixture (exit 0 all as expected, 1 not)
       node core/contracts/validate.mjs --schema <name> <file>...  check files (.json, or .md front matter for brief/report)
       node core/contracts/validate.mjs --list                     list the contract names
exit: 0 ok, 1 invalid, 2 usage, unreadable file or broken schema`;

// Contract name (event) -> schema file (event.schema.json). common holds shared pieces and is never checked alone.
export function loadSchemas(dir = here) {
  const schemas = new Map();
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.schema.json')).sort()) {
    schemas.set(f, JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')));
  }
  return schemas;
}
export const contractNames = (schemas) => [...schemas.keys()].map((f) => f.replace(/\.schema\.json$/, '')).filter((n) => n !== 'common');

// Cross-field rules JSON Schema cannot say. Each decision found anywhere in a document: recommended and answer are among its options,
// and a choose card has one variant per option.
function decisionsIn(name, v) {
  if (!v || typeof v !== 'object') return [];
  if (name === 'decision') return [['', v]];
  if (name === 'event' && v.kind === 'decision.asked' && v.data) return [['/data/decision', v.data.decision]];
  if (name === 'api-work' && Array.isArray(v.queue)) return v.queue.map((c, i) => [`/queue/${i}/decision`, c && c.decision]);
  if (name === 'api-work-item' && Array.isArray(v.decisions)) return v.decisions.map((d, i) => [`/decisions/${i}`, d]);
  if (name === 'api-work-stream' && v.type === 'card' && v.data) return [['/data/decision', v.data.decision]];
  return [];
}
function decisionRule(p, d) {
  if (!d || !Array.isArray(d.options)) return [];
  const errs = [];
  if (!d.options.includes(d.recommended)) errs.push({ path: `${p}/recommended`, keyword: 'rule', message: 'must be one of the options' });
  if (typeof d.answer === 'string' && !d.options.includes(d.answer)) errs.push({ path: `${p}/answer`, keyword: 'rule', message: 'must be one of the options' });
  const variants = Array.isArray(d.variants) ? d.variants.map((x) => x && x.option).sort().join('|') : null;
  if (variants !== null && variants !== [...d.options].sort().join('|')) errs.push({ path: `${p}/variants`, keyword: 'rule', message: 'needs exactly one variant per option' });
  return errs;
}
function queueRule(name, v) {
  if (name !== 'api-work' || !v || !Array.isArray(v.queue)) return [];
  const errs = [];
  v.queue.forEach((c, i) => {
    if (c && c.decision && c.decision.answer !== null) errs.push({ path: `/queue/${i}/decision/answer`, keyword: 'rule', message: 'a queued card is open (answer null)' });
    if (i && c && v.queue[i - 1] && c.ageH > v.queue[i - 1].ageH) errs.push({ path: `/queue/${i}/ageH`, keyword: 'rule', message: 'the queue is oldest first' });
  });
  return errs;
}
function rules(name, v) {
  return [...decisionsIn(name, v).flatMap(([p, d]) => decisionRule(p, d)), ...queueRule(name, v)];
}

let cache = null;
function checkerFor(dir) {
  if (cache && cache.dir === dir) return cache;
  const schemas = loadSchemas(dir);
  const checker = makeChecker(schemas);
  checker.lint();
  cache = { dir, schemas, checker };
  return cache;
}

// The one call lanes use: validate('event', obj) -> { ok, errors: ["/data/stage: enum: must be one of ..."] }.
export function validate(name, value, dir = here) {
  const { checker } = checkerFor(dir);
  const errs = [...checker.check(`${name}.schema.json`, value), ...rules(name, value)];
  return { ok: errs.length === 0, errors: errs.map(formatError) };
}

// A file as the contract sees it: JSON, or a markdown file's front matter. Throws with a plain reason when it cannot be read.
export function readDoc(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (!file.endsWith('.md')) return JSON.parse(text);
  const fm = parseFrontMatter(text);
  if (!fm.ok) throw new Error(fm.error);
  return fm.data;
}

// fixtures/<name>/valid/* must pass; fixtures/<name>/invalid/*.json are { why, expect, doc } and must fail with an error containing expect.
export function runFixtures(dir = here) {
  const results = [];
  const root = path.join(dir, 'fixtures');
  for (const name of contractNames(checkerFor(dir).schemas)) {
    for (const kind of ['valid', 'invalid']) {
      const folder = path.join(root, name, kind);
      if (!fs.existsSync(folder)) { results.push({ name: `${name}/${kind}`, pass: false, detail: 'no fixtures folder' }); continue; }
      for (const f of fs.readdirSync(folder).sort()) results.push(fixtureResult(dir, name, kind, path.join(folder, f), `${name}/${kind}/${f}`));
    }
  }
  return results;
}
function fixtureResult(dir, name, kind, file, rel) {
  let doc, wrap;
  try { wrap = readDoc(file); doc = kind === 'valid' ? wrap : wrap.doc; } catch (e) { return { name: rel, pass: false, detail: `unreadable: ${e.message}` }; }
  const r = validate(name, doc, dir);
  if (kind === 'valid') return { name: rel, pass: r.ok, detail: r.errors.slice(0, 3).join('; ') };
  if (!wrap.why || !wrap.expect) return { name: rel, pass: false, detail: 'an invalid fixture needs "why" and "expect"' };
  const named = r.errors.some((e) => e.includes(wrap.expect));
  return { name: rel, pass: !r.ok && named, detail: r.ok ? 'was accepted' : `no error contains "${wrap.expect}": ${r.errors.slice(0, 3).join('; ')}` };
}

function checkFiles(name, files) {
  let bad = 0;
  for (const f of files) {
    let doc;
    try { doc = readDoc(f); } catch (e) { console.log(`unreadable ${f}: ${e.message}`); return 2; }
    const r = validate(name, doc);
    console.log(`${r.ok ? 'ok' : 'invalid'} ${f}`);
    for (const e of r.errors) console.log(`  ${e}`);
    if (!r.ok) bad++;
  }
  return bad ? 1 : 0;
}

export function main(argv) {
  try {
    const names = contractNames(checkerFor(here).schemas);
    if (argv[0] === '--list') { console.log(names.join('\n')); return 0; }
    if (argv[0] === '--schema') {
      if (!names.includes(argv[1]) || argv.length < 3) { console.log(USAGE); return 2; }
      return checkFiles(argv[1], argv.slice(2));
    }
    if (argv.length) { console.log(USAGE); return 2; }
    const results = runFixtures();
    for (const r of results.filter((x) => !x.pass)) console.log(`FAIL: ${r.name}: ${r.detail}`);
    const failed = results.filter((x) => !x.pass).length;
    console.log(`Contracts fixtures: ${results.length - failed} passed, ${failed} failed`);
    return failed ? 1 : 0;
  } catch (e) {
    console.log(`broken contracts: ${e.message}`);
    return 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = main(process.argv.slice(2));
