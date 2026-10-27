// @ts-check
// Importer: the Yard's idea list and Jordan's idea-level facts -> snapshot events (read only; the state folder is never written).
//   - ideas.json (kitchen/ideas.ps1): every idea with its status, score, size, source and order -> one x.yard.ideas event per change.
//   - ledger-links.json (kitchen/ledger.ps1 link): proof recorded by hand for work done outside the Yard -> one x.yard.links event.
//   - pass-actions.jsonl: Jordan's own drops of an idea in Chef (op ideas-drop, ok) -> one x.yard.drops event.
// Ideas are not work orders: they make no rows. The view uses them for the ledger.json export (the Board's Ledger tab) and parity.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { isoOrNull, text } from './ids.mjs';

const hash = (/** @type {unknown} */ v) => crypto.createHash('sha1').update(JSON.stringify(v)).digest('hex').slice(0, 16);
/** @param {string} p @returns {{ ok: boolean, doc?: any, why: string }} */
function readJson(p) {
  if (!fs.existsSync(p)) return { ok: false, why: 'missing' };
  try { return { ok: true, doc: JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')), why: '' }; } catch { return { ok: false, why: 'not JSON' }; }
}
const ID = /^(I\d{1,5}|J\d{1,5}|[A-Za-z][A-Za-z0-9]{0,5}-\d{1,4}|R-\d{1,4})$/;

/** @param {string} state @param {{ now?: Date }} [opt] */
export function importIdeas(state, opt = {}) {
  const at = (opt.now || new Date()).toISOString(); /** @type {any[]} */ const events = [];
  const report = /** @type {any} */ ({});
  const add = (/** @type {string} */ kind, /** @type {any} */ data) => events.push({ family: `ideas:${kind}`, value: hash(data), at, actor: 'import', kind, wo: null, data, proof: null });
  const ideas = readJson(path.join(state, 'ideas.json'));
  const items = Array.isArray(ideas.doc?.items) ? ideas.doc.items.filter((/** @type {any} */ i) => /^I\d+$/.test(String(i?.id || ''))).map((/** @type {any} */ i) => ({
    id: String(i.id), title: text(i.title || i.goal, 300) || String(i.id), status: text(i.status, 20), source: text(i.source, 300), score: Number(i.score) || 0, size: text(i.size, 10),
    at: isoOrNull(i.at), job: /^J\d+$/.test(String(i.job || '')) ? String(i.job) : null })) : [];
  report.ideas = { ok: ideas.ok, why: ideas.why, items: items.length };
  add('x.yard.ideas', { ok: ideas.ok, why: ideas.why, items });
  const links = readJson(path.join(state, 'ledger-links.json'));
  /** @type {Record<string, any>} */ const l = {};
  if (links.doc && typeof links.doc === 'object') for (const [k, v] of Object.entries(links.doc)) if (ID.test(k) && v && typeof v === 'object') l[k] = { proof: text(/** @type {any} */ (v).proof, 300), why: text(/** @type {any} */ (v).why, 300), at: isoOrNull(/** @type {any} */ (v).at), by: text(/** @type {any} */ (v).by, 20) };
  report.links = { ok: links.ok || links.why === 'missing', why: links.why, count: Object.keys(l).length };
  add('x.yard.links', { links: l });
  /** @type {Record<string, string>} */ const drops = {};
  let raw = ''; try { raw = fs.readFileSync(path.join(state, 'pass-actions.jsonl'), 'utf8'); } catch { }
  for (const line of raw.split('\n')) {
    if (!line.includes('"ideas-drop"')) continue;
    try { const e = JSON.parse(line); if (e.op === 'ideas-drop' && e.ok && /^I\d+$/.test(String(e.id))) drops[String(e.id)] = isoOrNull(e.ts) || at; } catch { }
  }
  report.drops = Object.keys(drops).length;
  add('x.yard.drops', { drops });
  return { events, report };
}
