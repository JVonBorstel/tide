// Owns the public/export path of contract records: values marked x-local-only (proof, out, args) may name this PC's files, so before a
// record leaves the PC (a PR body, a public file, a CI log, a cloud task) toPublic strips those paths and publicErrors names them.
// Called by any lane that exports a record, tests/core/contracts/test-contracts.mjs, and by hand: node core/contracts/public.mjs <contract> <file>...
import path from 'node:path'; import { pathToFileURL } from 'node:url';
import { localOnlyPaths, readDoc, validate } from './validate.mjs';

// A path on this PC: a drive letter, a \\host share, a home path (~/ or ~user/), or a Unix root folder that holds people's or system files.
// Not matched inside a URL (github.com/home/... stays): the character before must not be a word, ':', '/', '.', '~' or '-'.
export const LOCAL_PATH = /(?<![\w:/.~-])(?:[A-Za-z]:[\\/]|\\\\[^\s\\/]+[\\/]|~[A-Za-z0-9._-]*[\\/]|\/(?:home|Users|root|srv|var|tmp|mnt|opt|etc|private|Volumes)\/)[^\s"'<>|]*/g;
export const STRIPPED = '<local path>';

const at = (doc, pointer) => pointer.split('/').slice(1).reduce((n, k) => (n == null ? undefined : n[k]), doc);

// Every string inside a value, with its pointer (a local-only value may be an object: activity args).
function strings(value, pointer, out = []) {
  if (typeof value === 'string') out.push([pointer, value]);
  else if (value && typeof value === 'object') for (const [k, v] of Object.entries(value)) strings(v, `${pointer}/${k}`, out);
  return out;
}
function setAt(doc, pointer, v) {
  const keys = pointer.split('/').slice(1);
  const last = keys.pop();
  const parent = keys.reduce((n, k) => n[k], doc);
  parent[last] = v;
}

// Reject mode: one error per local-only string that names a local path. Empty = safe to export as it is.
export function publicErrors(name, doc) {
  const errs = [];
  for (const p of localOnlyPaths(name, doc)) {
    for (const [sp, s] of strings(at(doc, p), p)) if (new RegExp(LOCAL_PATH.source).test(s)) errs.push(`${sp}: local-only: names a path on this PC`);
  }
  return errs;
}

// Strip mode: a copy with every local path in a local-only value replaced by "<local path>"; the record stays valid for its contract.
export function toPublic(name, doc) {
  const copy = structuredClone(doc);
  const stripped = [];
  for (const p of localOnlyPaths(name, copy)) {
    for (const [sp, s] of strings(at(copy, p), p)) {
      const clean = s.replace(LOCAL_PATH, STRIPPED);
      if (clean !== s) { setAt(copy, sp, clean); stripped.push(sp); }
    }
  }
  return { doc: copy, stripped };
}

export function main(argv) {
  if (argv.length < 2) { console.log('usage: node core/contracts/public.mjs <contract> <file>...   exit 0 safe to export, 1 a local path or invalid, 2 unreadable'); return 2; }
  let bad = 0;
  for (const f of argv.slice(1)) {
    let doc;
    try { doc = readDoc(f); } catch (e) { console.log(`unreadable ${f}: ${e.message}`); return 2; }
    const errs = [...validate(argv[0], doc).errors, ...publicErrors(argv[0], doc)];
    console.log(`${errs.length ? 'not public' : 'public ok'} ${f}`);
    for (const e of errs) console.log(`  ${e}`);
    if (errs.length) bad++;
  }
  return bad ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = main(process.argv.slice(2));
