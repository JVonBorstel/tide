// @ts-check
// Importers: roadmaps and the lobe's decisions -> snapshot events (read only).
//   - importRoadmaps: each repo that opts in ("roadmap": "map/roadmap.json" in its kitchen.repo.json, kitchen/roadmap-lib.ps1) -> one
//     x.local.roadmap event per change: its items (id, wave, title, size, depends_on, owner_only). Read from the main checkout, as the Yard
//     does. A repo with no roadmap is skipped; a broken roadmap says why (fail closed: no items are guessed).
//   - importLobe: the lobe's flags.json (ZEITGEISTD_HOME, else <state>\lobe; written by zeitgeistd `decisions run`) -> one x.lobe.flags
//     event: decisions ready for Jordan and post-mortems due (ids, days and dates only; the question text stays on the World tab).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { isoOrNull, text } from './ids.mjs';

const hash = (/** @type {unknown} */ v) => crypto.createHash('sha1').update(JSON.stringify(v)).digest('hex').slice(0, 16);
const ITEM_ID = /^[A-Za-z][A-Za-z0-9]{0,5}-\d{1,4}$/;
const DEC_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$/;
/** @param {string} p */
const readJsonBom = (p) => JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, ''));

/** One repo's roadmap, or why not. @param {string} repo the main checkout @param {string} name */
export function roadmapOf(repo, name) {
  const out = /** @type {any} */ ({ repo: name, ok: false, why: '', items: [] });
  const cfgPath = path.join(repo, 'kitchen.repo.json');
  if (!fs.existsSync(cfgPath)) { out.why = 'no kitchen.repo.json'; return out; }
  let cfg; try { cfg = readJsonBom(cfgPath); } catch { out.why = 'kitchen.repo.json is not JSON'; return out; }
  const rel = typeof cfg?.roadmap === 'string' ? cfg.roadmap : '';
  if (!rel) { out.why = 'no roadmap'; return out; }
  if (/[*?]/.test(rel) || !/\.json$/i.test(rel) || path.isAbsolute(rel) || rel.split(/[\\/]/).includes('..')) { out.why = `roadmap '${text(rel, 80)}' is not one relative .json path`; return out; }
  let rm; try { rm = readJsonBom(path.join(repo, rel)); } catch { out.why = `cannot read ${text(rel, 80)}`; return out; }
  if (!Array.isArray(rm?.waves)) { out.why = `${text(rel, 80)} has no waves list`; return out; }
  for (const w of rm.waves) {
    for (const it of Array.isArray(w?.items) ? w.items : []) {
      if (!ITEM_ID.test(String(it?.id || ''))) { out.why = `${text(rel, 80)}: an item id is not like B-01 (${text(it?.id, 20)})`; out.items = []; return out; }
      out.items.push({ id: String(it.id), wave: text(w.id, 20), title: text(it.title, 300) || String(it.id), size: text(it.size, 10), depends_on: Array.isArray(it.depends_on) ? it.depends_on.map(String) : [], owner_only: it.owner_only === true });
    }
  }
  out.ok = true; return out;
}

/** @param {{ repos: Array<{ path: string, name: string }>, now?: Date }} o */
export function importRoadmaps(o) {
  const at = (o.now || new Date()).toISOString(); /** @type {any[]} */ const events = []; const report = /** @type {any[]} */ ([]);
  for (const r of o.repos) {
    const rm = roadmapOf(r.path, r.name);
    report.push({ repo: r.name, ok: rm.ok, why: rm.why, items: rm.items.length });
    if (!rm.ok && /^no (kitchen\.repo\.json|roadmap)$/.test(rm.why)) continue;   // not opted in: nothing to say
    events.push({ key: `roadmap:${r.name}:${hash(rm)}`, at, actor: 'import', kind: 'x.local.roadmap', wo: null, data: { ...rm, path: r.path }, proof: null });
  }
  return { events, report };
}

/** The lobe home, as kitchen/ledger.ps1 and the Board find it. @param {string} state */
export function lobeHome(state) {
  let h = String(process.env.ZEITGEISTD_HOME || '').trim();
  if (/^~(?=$|[\\/])/.test(h)) h = os.homedir() + h.slice(1);
  return h ? path.resolve(h) : path.join(state, 'lobe');
}

/** @param {string} state @param {{ now?: Date, home?: string }} [opt] */
export function importLobe(state, opt = {}) {
  const at = (opt.now || new Date()).toISOString(); const p = path.join(opt.home || lobeHome(state), 'flags.json');
  const data = /** @type {any} */ ({ ok: false, why: '', missing: false, updated: null, decisionReady: [], postMortemDue: [] });
  if (!fs.existsSync(p)) { data.missing = true; data.why = 'no flags.json yet (the lobe writes it on its decisions run)'; }
  else {
    const st = fs.statSync(p); let doc = null;
    if (st.isDirectory()) data.why = 'flags.json cannot be read (it is not a file)';
    else if (st.size > 1024 * 1024) data.why = 'flags.json cannot be read (it is over 1 MB)';
    else { try { doc = readJsonBom(p); } catch { data.why = 'flags.json cannot be read (it is not JSON)'; } }
    if (doc && (typeof doc !== 'object' || Array.isArray(doc) || !('decisionReady' in doc) || !('postMortemDue' in doc))) { data.why = 'flags.json cannot be read (it has no decisionReady or postMortemDue list)'; doc = null; }
    if (doc) {
      data.ok = true; data.updated = isoOrNull(doc.updated);
      for (const d of Array.isArray(doc.decisionReady) ? doc.decisionReady : []) if (d && DEC_ID.test(String(d.id))) data.decisionReady.push({ id: String(d.id), readyAt: isoOrNull(d.ready_at) });
      for (const d of Array.isArray(doc.postMortemDue) ? doc.postMortemDue : []) if (d && DEC_ID.test(String(d.id)) && ['30', '60', '90'].includes(String(d.day))) data.postMortemDue.push({ id: String(d.id), day: Number(d.day), dueAt: isoOrNull(d.due_at), expiresAt: isoOrNull(d.expires_at) });
    }
  }
  return { events: [{ key: `lobe:flags:${hash(data)}`, at, actor: 'import', kind: 'x.lobe.flags', wo: null, data, proof: null }], report: { ok: data.ok, why: data.why, decisionsReady: data.decisionReady.length, postMortemsDue: data.postMortemDue.length } };
}
