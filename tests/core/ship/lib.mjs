// Owns the helpers of the ship path's tests: named checks, and throwaway git repos (a bare "origin" plus clones) in the temp folder.
// Called by tests/core/ship/test-*.mjs. Every repo is synthetic and removed at the end; nothing touches the real repo or the state folder.
// @ts-check
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path';
import { git } from '../../../core/ship/git.mjs';

export const EMAIL = '1000001+example-owner@users.noreply.github.com';
export const NAME = 'Example Owner';

/** @typedef {{ name: string, pass: boolean }} Result */
/** @param {Result[]} results */
export const checker = (results) => /** @param {string} name @param {unknown} pass @param {string} [detail] */ (name, pass, detail = '') =>
  results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });

const made = [];
/** A new empty folder under the temp folder. */
export function tempDir(tag = 'ship') {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), `tide-${tag}-`));
  made.push(d);
  return d;
}
export function cleanup() {
  for (const d of made.splice(0)) { try { fs.rmSync(d, { recursive: true, force: true, maxRetries: 3 }); } catch { /* a locked temp folder is left for the OS */ } }
}

/** Run git and throw on failure (test setup only). @param {string} cwd @param {string[]} args */
export function g(cwd, args) {
  const r = git(cwd, args);
  if (!r.ok) throw new Error(`git ${args.join(' ')} failed in ${cwd}: ${r.err}`);
  return r.out;
}

/** @param {string} dir @param {Record<string, string>} files @param {string} msg */
export function commit(dir, files, msg) {
  for (const [rel, text] of Object.entries(files)) {
    const f = path.join(dir, rel);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, text);
  }
  g(dir, ['add', '-A']);
  g(dir, ['commit', '-q', '-m', msg]);
  return g(dir, ['rev-parse', 'HEAD']);
}

/** @param {string} dir @param {string} [email] */
export function setIdentity(dir, email = EMAIL) {
  g(dir, ['config', 'user.email', email]);
  g(dir, ['config', 'user.name', NAME]);
  g(dir, ['config', 'commit.gpgsign', 'false']);
}

/**
 * A bare origin with main holding `files`, and a clone of it. Returns { origin, clone, base }.
 * @param {Record<string, string>} files
 */
export function originWithClone(files = { 'README.md': 'example\n', 'src/a.txt': 'one\ntwo\nthree\n' }) {
  const origin = path.join(tempDir('origin'), 'example-repo.git');
  g(path.dirname(origin), ['init', '-q', '--bare', '-b', 'main', origin]);
  const seed = path.join(tempDir('seed'), 'seed');
  g(path.dirname(seed), ['clone', '-q', origin, seed]);
  setIdentity(seed);
  g(seed, ['checkout', '-q', '-b', 'main']);
  const base = commit(seed, files, 'first');
  g(seed, ['push', '-q', 'origin', 'main']);
  const clone = path.join(tempDir('clone'), 'clone');
  g(path.dirname(clone), ['clone', '-q', origin, clone]);
  setIdentity(clone);
  return { origin, clone, seed, base };
}
