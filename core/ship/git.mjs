// Owns the one way the ship path (core/ship) runs git: an argument list, no shell, a time limit, and a guard that refuses every force push.
// Called by core/ship/queue.mjs, core/ship/freshen-pr.mjs, core/ship/docs.mjs and tests/core/ship/*. Zero dependencies; Node 18 or later.
// @ts-check
import { spawnSync } from 'node:child_process';

/** The noreply address GitHub gives an account: <id>+<login>@users.noreply.github.com. */
export const NOREPLY = /^\d+\+[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})@users\.noreply\.github\.com$/;
/** The one identity Tide's merges and Resurvey commits are made as by default: the owner's account noreply address (kitchen/BUILDING.md). */
export const OWNER_NOREPLY = '104696717+VonBorstel-J@users.noreply.github.com';

/**
 * Why a git argument list would rewrite history on a remote, or '' when it would not. A push is refused when it names --force (any
 * spelling), -f, --mirror, --delete, -d or a +refspec. Never forcing is a rule of the ship path, not an option.
 * @param {string[]} args
 */
export function forceReason(args) {
  const i = args.indexOf('push');
  if (i < 0) return '';
  for (const a of args.slice(i + 1)) {
    if (/^--force(-with-lease|-if-includes)?(=|$)/.test(a)) return `a force push (${a}) is never run`;
    if (/^-[A-Za-z]*f[A-Za-z]*$/.test(a) && !a.startsWith('--')) return `a force push (${a}) is never run`;
    if (a === '--mirror' || a === '--delete' || a === '-d') return `a push that deletes or mirrors (${a}) is never run`;
    if (a.startsWith('+')) return `a forced refspec (${a}) is never run`;
    if (a.startsWith(':')) return `a delete refspec (${a}) is never run`;
  }
  return '';
}

/**
 * Run git in a folder. Returns { ok, code, out, err }; never throws for a git failure (the caller names it), only for a force push.
 * @param {string} cwd
 * @param {string[]} args
 * @param {{ timeoutMs?: number, env?: Record<string, string> }} [opt]
 */
export function git(cwd, args, opt = {}) {
  const why = forceReason(args);
  if (why) throw new Error(`refused: ${why}`);
  const r = spawnSync('git', args, {
    cwd, encoding: 'utf8', timeout: opt.timeoutMs ?? 120000, windowsHide: true,
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0', ...(opt.env || {}) },
  });
  const err = r.error ? String(r.error.message) : (r.stderr || '');
  return { ok: r.status === 0, code: r.status ?? -1, out: (r.stdout || '').trim(), err: err.trim() };
}

/**
 * The files git left unmerged (conflicted) in a worktree, sorted.
 * @param {string} cwd
 */
export function conflictedFiles(cwd) {
  const r = git(cwd, ['diff', '--name-only', '--diff-filter=U']);
  return r.out ? r.out.split('\n').map((s) => s.trim()).filter(Boolean).sort() : [];
}

/**
 * The files that differ between two commits (a..b, by tree), sorted.
 * @param {string} cwd
 * @param {string} a
 * @param {string} b
 */
export function changedFiles(cwd, a, b) {
  const r = git(cwd, ['diff', '--name-only', a, b]);
  return r.ok && r.out ? r.out.split('\n').map((s) => s.trim()).filter(Boolean).sort() : [];
}
