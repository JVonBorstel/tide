// Owns Tide's feature flags: reads and checks flags.json, folds flag.set events into the current values, and answers "is this flag on?".
// Called by the Board (lane L5, through the server), the ship path (core/ship/queue.mjs), tests/core/ship/test-flags.mjs and by hand (usage below).
// @ts-check
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath, pathToFileURL } from 'node:url';
import { makeChecker, formatError } from '../contracts/jsonschema.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const FLAGS_FILE = path.resolve(here, '..', '..', 'flags.json');
const SCHEMA_FILE = path.join(here, 'flags.schema.json');
const NAME = /^[a-z][a-z0-9.-]*$/; // the same rule as a flag.set event's data.flag (core/contracts/event.schema.json)
const USAGE = `usage: node core/ship/flags.mjs check [<flags.json>]            check the file against core/ship/flags.schema.json
       node core/ship/flags.mjs list [<flags.json>]             every flag, its default and what it changes
       node core/ship/flags.mjs get <name> [--events <file.jsonl>]  on or off (an unknown flag is off)
exit: 0 ok (get: on), 1 invalid (get: off), 2 usage or an unreadable file`;

/** @typedef {{ default: false, what: string, lane: string }} FlagDecl */
/** @typedef {{ ok: boolean, errors: string[], flags: Map<string, FlagDecl> }} FlagSet */

/**
 * Check a parsed flags.json. Schema errors are named by JSON pointer.
 * @param {unknown} doc
 * @returns {FlagSet}
 */
export function checkFlags(doc) {
  const schema = JSON.parse(fs.readFileSync(SCHEMA_FILE, 'utf8'));
  const checker = makeChecker(new Map([['flags.schema.json', schema]]));
  const errors = checker.check('flags.schema.json', doc).map(formatError);
  const flags = new Map();
  const raw = doc && typeof doc === 'object' && /** @type {any} */ (doc).flags;
  if (raw && typeof raw === 'object') {
    for (const [name, decl] of Object.entries(raw)) {
      if (name.length > 60) errors.push(`/flags/${name}: maxLength: a flag name is at most 60 characters (the flag.set event's limit)`);
      else if (NAME.test(name) && decl && typeof decl === 'object') flags.set(name, decl);
    }
  }
  return { ok: errors.length === 0, errors, flags: errors.length ? new Map() : flags };
}

/**
 * Read and check flags.json. A missing or unreadable file is an error with its reason, never "no flags".
 * @param {string} [file]
 * @returns {FlagSet}
 */
export function readFlags(file = FLAGS_FILE) {
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {
    return { ok: false, errors: [`${file}: cannot be read as JSON (${/** @type {Error} */ (e).message})`], flags: new Map() };
  }
  return checkFlags(doc);
}

/**
 * The current values from flag.set events (the same fold the ledger keeps as a projection), in seq order. An event that turns a flag
 * on without a decision id is ignored: the contract refuses it, and a flag never turns on without Jordan's yes.
 * @param {Array<{ seq?: number, kind?: string, data?: any }>} events
 * @returns {Record<string, boolean>}
 */
export function foldFlagEvents(events) {
  /** @type {Record<string, boolean>} */
  const cur = {};
  const sorted = [...events].filter((e) => e && e.kind === 'flag.set' && e.data).sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0));
  for (const e of sorted) {
    const { flag, on, decision } = e.data;
    if (typeof flag !== 'string' || typeof on !== 'boolean') continue;
    if (on && !(typeof decision === 'string' && /^D-[0-9]+$/.test(decision))) continue;
    cur[flag] = on;
  }
  return cur;
}

/**
 * Is a flag on? Off unless it is declared in flags.json AND the current values say on. An unknown flag is off, a broken flags.json
 * turns every flag off, and a current value for an undeclared flag is ignored.
 * @param {string} name
 * @param {{ declared?: FlagSet, current?: Record<string, boolean> }} [opt]
 */
export function isOn(name, opt = {}) {
  const declared = opt.declared ?? readFlags();
  if (!declared.ok || !declared.flags.has(name)) return false;
  const cur = opt.current ?? {};
  return Object.prototype.hasOwnProperty.call(cur, name) ? cur[name] === true : declared.flags.get(name)?.default === true;
}

/** @param {string} file */
function readEvents(file) {
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).filter((l) => l.trim()).map((l) => JSON.parse(l));
}

/** @param {string[]} argv @returns {number} */
export function main(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === 'check' || cmd === 'list') {
    const set = readFlags(rest[0] || FLAGS_FILE);
    if (!set.ok) { for (const e of set.errors) console.log(`FAIL: ${e}`); console.log(`Flags: invalid (${set.errors.length} errors)`); return 1; }
    if (cmd === 'list') for (const [n, d] of set.flags) console.log(`${n}  off by default  (${d.lane})  ${d.what}`);
    console.log(`Flags: ${set.flags.size} declared, all off by default`);
    return 0;
  }
  if (cmd === 'get' && rest[0]) {
    const at = rest.indexOf('--events');
    let current = {};
    if (at >= 0) {
      if (!rest[at + 1]) { console.log(USAGE); return 2; }
      try { current = foldFlagEvents(readEvents(rest[at + 1])); } catch (e) { console.log(`flags: cannot read ${rest[at + 1]} (${/** @type {Error} */ (e).message})`); return 2; }
    }
    const declared = readFlags();
    const on = isOn(rest[0], { declared, current });
    const why = !declared.ok ? ' (flags.json is invalid, so every flag is off)' : !declared.flags.has(rest[0]) ? ' (not declared in flags.json)' : '';
    console.log(`${rest[0]}: ${on ? 'on' : 'off'}${why}`);
    return on ? 0 : 1;
  }
  console.log(USAGE);
  return 2;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = main(process.argv.slice(2));
