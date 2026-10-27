// @ts-check
// Everything the ledger writes for others to read goes through here: work.json and ledger.next.json (the Board reads them, and the
// Board is reached from the phone), every --json answer of cli.mjs, and any record that would leave this PC (an API answer, a cloud task,
// a PR body). tide.db itself keeps the raw facts; it never leaves the PC.
//   - redactText: free text (goals, titles, why, proof, notes) loses this PC's paths, email addresses, private host names and addresses,
//     and the private words of the state folder's list (private repo names, job-hunt companies): each is replaced by a fixed marker.
//   - a private work order (wo.created private) shows no goal at all, only "a private work order" (as the City does, docs/changes/city-g2).
//   - publicEvent: an x.* event's data is local by nature (paths, idea titles, Yard facts) and is dropped whole; then
//     core/contracts/public.mjs toPublic strips local paths from the x-local-only fields (proof). publicRow: the same for a row.
import fs from 'node:fs';
import { toPublic, LOCAL_PATH } from '../contracts/public.mjs';
import { CONTRACT_V } from './store.mjs';

export const MARK = { path: '<local path>', email: '<email>', host: '<private host>', word: '<private>', order: 'a private work order' };
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
// tailnet and home-network names, and private IPv4 addresses (10/8, 172.16/12, 192.168/16, 100.64/10 used by Tailscale)
const HOST = /\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:ts\.net|local|lan|internal|home\.arpa)\b/gi;
const IP = /\b(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d{1,3}\.\d{1,3}\b/g;
const esc = (/** @type {string} */ s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * The private words: a JSON list in the state folder (never in the repo), plus names the events mark private. Missing file: none.
 * @param {string | undefined} file a JSON array of strings, or { "words": [...] }
 * @returns {{ words: string[], why: string }}
 */
export function readPrivateWords(file) {
  if (!file || !fs.existsSync(file)) return { words: [], why: 'no private words list' };
  try {
    const d = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
    const list = Array.isArray(d) ? d : Array.isArray(d?.words) ? d.words : null;
    if (!list) return { words: [], why: 'the private words list is not a JSON list' };
    return { words: list.map((w) => String(w).trim()).filter((w) => w.length >= 2), why: '' };
  } catch { return { words: [], why: 'the private words list is not JSON' }; }
}

/** @param {{ privateWords?: string[] }} [o] @returns {(s: string) => string} */
export function makeRedactor(o = {}) {
  const words = [...new Set((o.privateWords || []).filter(Boolean))].sort((a, b) => b.length - a.length);
  const W = words.length ? new RegExp(`(?<![A-Za-z0-9])(?:${words.map(esc).join('|')})(?![A-Za-z0-9])`, 'gi') : null;
  return (s) => {
    let t = String(s).replace(new RegExp(LOCAL_PATH.source, 'g'), MARK.path).replace(EMAIL, MARK.email).replace(HOST, MARK.host).replace(IP, MARK.host);
    if (W) t = t.replace(W, MARK.word);
    return t;
  };
}

/** Every string in a value, redacted (keys are kept). @param {any} v @param {(s: string) => string} redact @returns {any} */
export function redactDeep(v, redact) {
  if (typeof v === 'string') return redact(v);
  if (Array.isArray(v)) return v.map((x) => redactDeep(x, redact));
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, redactDeep(x, redact)]));
  return v;
}

/**
 * The private work orders of a view, and the private words its events imply (the repo names of private orders).
 * @param {any} view a buildView answer (with internal.fold)
 */
export function privateOf(view) {
  const ids = new Set(), aliases = new Set(), words = new Set();
  for (const w of view.internal?.fold?.wos?.values?.() || []) {
    if (!w.private) continue;
    ids.add(w.id); if (w.alias) aliases.add(w.alias);
    const rp = String(w.yard?.repoPath || '').split(/[\\/]/).filter(Boolean).pop(); if (rp) words.add(rp);
    const gh = String(w.repo || '').split('/').pop(); if (gh) words.add(gh);
  }
  return { ids, aliases, words: [...words] };
}

/**
 * work.json, ready to share: private orders show no goal; every string is redacted.
 * @param {any} work the view without internal @param {{ ids: Set<string> }} priv @param {(s: string) => string} redact
 */
export function shareWork(work, priv, redact) {
  const rows = work.rows.map((/** @type {any} */ r) => (priv.ids.has(r.id) ? { ...r, goal: MARK.order } : r));
  const queue = (q) => q.map((/** @type {any} */ c) => (c.decision?.wo && priv.ids.has(c.decision.wo) ? { ...c, goal: MARK.order } : c));
  return redactDeep({ ...work, rows, queue: queue(work.queue), queueAll: queue(work.queueAll) }, redact);
}

/**
 * ledger.next.json, ready to share: a private order's item and chain show no title; every string is redacted.
 * @param {any} doc exportLedgerJson's answer @param {{ ids: Set<string>, aliases: Set<string> }} priv @param {(s: string) => string} redact
 */
export function shareLedger(doc, priv, redact) {
  const isPriv = (/** @type {any} */ x) => priv.ids.has(String(x.wo || '')) || priv.aliases.has(String(x.id || '')) || (x.kind === 'idea' && (x.chain || []).some((/** @type {any} */ c) => priv.aliases.has(String(c.id))));
  const items = doc.items.map((/** @type {any} */ x) => (isPriv(x) ? { ...x, title: MARK.order, chain: (x.chain || []).map((/** @type {any} */ c) => ({ ...c, note: '' })) } : x));
  return redactDeep({ ...doc, items }, redact);
}

/** @param {any} e an event @returns {{ doc: any, stripped: string[] }} */
export function publicEvent(e) {
  const local = /^x\./.test(String(e?.kind || ''));
  const base = local ? { ...e, data: {} } : e;
  const r = toPublic('event', { v: CONTRACT_V, ...base });
  return { doc: r.doc, stripped: local ? ['/data', ...r.stripped] : r.stripped };
}

/** @param {any} row @returns {{ doc: any, stripped: string[] }} */
export function publicRow(row) { return toPublic('row', row); }
