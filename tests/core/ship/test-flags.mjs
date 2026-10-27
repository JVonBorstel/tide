// Owns the tests of Tide's feature flags (core/ship/flags.mjs, flags.json): acceptance lines of lane L4 row "flags".
// Called by tests/core/ship/test-ship.mjs.
// @ts-check
import path from 'node:path'; import fs from 'node:fs'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { readFlags, checkFlags, isOn, foldFlagEvents, FLAGS_FILE } from '../../../core/ship/flags.mjs';
import { validate } from '../../../core/contracts/validate.mjs';
import { tempDir } from './lib.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const decl = (over = {}) => ({ version: 1, flags: { 'board.sunrise': { default: false, what: 'An example slice behind a flag.', lane: 'L5', ...over } } });

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
export function run(check) {
  // ---- acceptance: an unknown flag is off
  const real = readFlags();
  check('flags: an unknown flag is off', real.ok && isOn('no.such-flag', { declared: real }) === false && isOn('no.such-flag', { declared: real, current: { 'no.such-flag': true } }) === false);
  const broken = checkFlags({ version: 1, flags: { 'Bad Name': {} } });
  check('flags: a broken flags.json turns every flag off', !broken.ok && isOn('board.sunrise', { declared: broken, current: { 'board.sunrise': true } }) === false);

  // ---- acceptance: the schema is validated
  check('flags: the repo flags.json passes its schema', real.ok, real.errors.join('; '));
  check('flags: the repo flags.json path is the repo root', FLAGS_FILE === path.join(repo, 'flags.json'));
  const bad = [
    ['a default of true', decl({ default: true }), '/flags/board.sunrise/default'],
    ['a missing what', { version: 1, flags: { 'board.sunrise': { default: false, lane: 'L5' } } }, 'required'],
    ['an unknown key', decl({ extra: 1 }), 'additionalProperties'],
    ['an upper-case name', { version: 1, flags: { 'Board.Sunrise': decl().flags['board.sunrise'] } }, '/flags'],
    ['a wrong version', { ...decl(), version: 2 }, '/version'],
    ['a name over 60 characters', { version: 1, flags: { [`a${'b'.repeat(60)}`]: decl().flags['board.sunrise'] } }, 'maxLength'],
  ];
  for (const [what, doc, expect] of bad) {
    const r = checkFlags(doc);
    check(`flags: the schema refuses ${what}`, !r.ok && r.errors.some((e) => e.includes(String(expect))), r.errors.join('; ') || 'accepted');
  }
  const dir = tempDir('flags');
  fs.writeFileSync(path.join(dir, 'flags.json'), '{ not json');
  const unreadable = readFlags(path.join(dir, 'flags.json'));
  check('flags: an unreadable flags.json is an error with its reason, not "no flags"', !unreadable.ok && /cannot be read as JSON/.test(unreadable.errors[0] || ''));
  const missing = readFlags(path.join(dir, 'none.json'));
  check('flags: a missing flags.json is an error', !missing.ok && missing.errors.length === 1);

  // ---- acceptance: a slice is off by default
  const sample = checkFlags(decl());
  check('flags: a slice is off by default (declared, no event)', sample.ok && isOn('board.sunrise', { declared: sample }) === false);
  for (const [n] of real.flags) check(`flags: ${n} is off by default in the repo flags.json`, isOn(n, { declared: real }) === false);

  // ---- a flip is Jordan's yes: flag.set events folded in seq order
  const ev = (seq, on, decision) => ({ v: '1.0', seq, at: '2030-01-07T09:12:00Z', actor: 'engine', kind: 'flag.set', wo: null, data: { flag: 'board.sunrise', on, decision }, proof: null });
  const on = [ev(12, true, 'D-7')];
  check('flags: the flag.set fixture shape passes the event contract', validate('event', on[0]).ok, validate('event', on[0]).errors.join('; '));
  check('flags: a flag.set event with a decision turns the slice on', isOn('board.sunrise', { declared: sample, current: foldFlagEvents(on) }) === true);
  check('flags: a flag.set on without a decision is ignored', isOn('board.sunrise', { declared: sample, current: foldFlagEvents([ev(12, true, null)]) }) === false);
  check('flags: events fold in seq order (the later off wins)', isOn('board.sunrise', { declared: sample, current: foldFlagEvents([ev(14, false, null), ev(12, true, 'D-7')]) }) === false);
  check('flags: other event kinds are ignored', Object.keys(foldFlagEvents([{ seq: 1, kind: 'merged', data: { flag: 'board.sunrise', on: true, decision: 'D-1' } }])).length === 0);

  // ---- the command line
  const cli = (args) => spawnSync(process.execPath, [path.join(repo, 'core/ship/flags.mjs'), ...args], { cwd: repo, encoding: 'utf8', timeout: 20000 });
  const c1 = cli(['check']);
  check('flags: "check" exits 0 on the repo file and prints the count', c1.status === 0 && /Flags: \d+ declared, all off by default/.test(c1.stdout), c1.stdout + c1.stderr);
  const c2 = cli(['get', 'no.such-flag']);
  check('flags: "get" of an unknown flag prints off and exits 1', c2.status === 1 && /off \(not declared/.test(c2.stdout), c2.stdout);
  const evFile = path.join(dir, 'events.jsonl');
  fs.writeFileSync(evFile, `${JSON.stringify({ ...ev(12, true, 'D-7'), data: { flag: 'ship.merge-queue', on: true, decision: 'D-7' } })}\n`);
  const c3 = cli(['get', 'ship.merge-queue', '--events', evFile]);
  check('flags: "get" with an event file that turns a declared flag on prints on and exits 0', c3.status === 0 && /: on$/m.test(c3.stdout), c3.stdout);
  const c4 = cli(['nonsense']);
  check('flags: a usage error exits 2', c4.status === 2);
}
