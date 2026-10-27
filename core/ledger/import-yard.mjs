// @ts-check
// Importer: the Yard's records -> work order events (read only; it never writes the state folder).
// Sources: jobs\J*.json (every live order), jobs\archive\index.jsonl (one summary per archived order), jobs-index.json (the count check),
// events.jsonl (close and kill reasons, replacements, quarantine reasons). Each Yard job J312 becomes work order WO-312 with alias J312.
// Every event carries a source key built from what it says, so a rerun over the same files adds 0 events, and a job that changed adds
// only the events for the change.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { woOfJob, isoOrNull, text } from './ids.mjs';

const hashOf = (/** @type {unknown} */ v) => crypto.createHash('sha1').update(JSON.stringify(v)).digest('hex').slice(0, 16);

/** @param {string} p */
function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')); } catch { return null; } }
/** @param {string} p @returns {any[]} */
function readJsonl(p) {
  let raw = ''; try { raw = fs.readFileSync(p, 'utf8'); } catch { return []; }
  const out = []; for (const l of raw.split('\n')) { if (!l.trim()) continue; try { out.push(JSON.parse(l)); } catch { } }
  return out;
}
const isCode = (/** @type {any} */ j) => Array.isArray(j?.steps) && j.steps.some((/** @type {any} */ s) => /merge\.ps1$/i.test(String(s?.script || '')));
const stepName = (/** @type {any} */ s) => String(s?.script || 'step').split(/[\\/]/).pop()?.replace(/\.ps1$/i, '').toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/^[^a-z]+/, '').slice(0, 40) || 'step';
const clampAttempt = (/** @type {unknown} */ n) => Math.min(20, Math.max(1, Number(n) || 1));
const REPO_RE = /^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+$/;

/** Yard status -> the stage it stands for (build-way 3.1). done is decided by the view (it needs proof on main). */
export const STAGE_OF_STATUS = /** @type {Record<string, string>} */ ({ pending: 'build', running: 'build', 'waiting-approval': 'jordan', 'needs-human': 'jordan', quarantined: 'build', failed: 'build' });

/**
 * @param {string} state the state folder (a scratch copy in tests and in shadow)
 * @param {{ now?: Date }} [opt]
 * @returns {{ events: any[], report: { jobs: number, archived: number, indexJobs: number | null, skipped: string[], unreadable: string[], paused: boolean } }}
 */
export function importYard(state, opt = {}) {
  const now = (opt.now || new Date()).toISOString();
  const report = { jobs: 0, archived: 0, indexJobs: /** @type {number | null} */ (null), skipped: /** @type {string[]} */ ([]), unreadable: /** @type {string[]} */ ([]), paused: false };
  if (!fs.existsSync(path.join(state, 'jobs'))) throw new Error(`no jobs folder in ${state}: is this a Yard state folder?`);
  const index = readJson(path.join(state, 'jobs-index.json'));
  report.indexJobs = index?.jobs && typeof index.jobs === 'object' ? Object.keys(index.jobs).length : null;
  // close, kill and quarantine facts from the Yard's own log (the last one per job wins)
  const closedBy = new Map(), quarantine = new Map();
  for (const e of readJsonl(path.join(state, 'events.jsonl'))) {
    const j = String(e?.job || ''); if (!/^J\d+$/.test(j)) continue;
    if (e.type === 'job.closed' || e.type === 'job.killed') {
      const reason = text(e.reason, 500); let replacedBy = /^J\d+$/.test(String(e.replacedBy || '')) ? String(e.replacedBy) : null;
      // as kitchen/ledger.ps1: with no proof and no drop, the first other order named in the reason replaces it ("re-cooked fresh as J143")
      if (!replacedBy && !e.proof && e.dropped !== true) replacedBy = [...reason.matchAll(/\b(J\d+)\b/g)].map((m) => m[1]).find((x) => x !== j) || null;
      closedBy.set(j, { type: e.type.slice(4), at: isoOrNull(e.ts), reason, replacedBy, dropped: e.dropped === true, by: text(e.by, 40), proof: e.proof ? text(e.proof, 300) : null });
    }
    if (e.type === 'job.quarantined') quarantine.set(j, text(e.reason, 500));
  }
  /** @type {any[]} */ const events = [];
  /** @param {string} key @param {string} at @param {string} kind @param {string} wo @param {object} data @param {string | null} [proof] */
  const add = (key, at, kind, wo, data, proof = null) => events.push({ key, at, actor: 'import', kind, wo, data, proof });
  // an observation that can change and change back: written only when it differs from the family's last value (store.mjs)
  /** @param {string} family @param {string} value @param {string} at @param {string} kind @param {string} wo @param {object} data @param {string | null} [proof] */
  const obs = (family, value, at, kind, wo, data, proof = null) => events.push({ family, value, at, actor: 'import', kind, wo, data, proof });

  /** @param {any} j @param {boolean} archived @param {string} fileAt */
  function one(j, archived, fileAt) {
    const id = String(j?.id || ''); const wo = woOfJob(id);
    if (!wo) { report.skipped.push(id || '(no id)'); return; }
    const created = isoOrNull(j.created) || fileAt;
    const goal = text(j.vars?.goal || j.name || id, 2000) || id;
    const repo = REPO_RE.test(String(j.vars?.github || '')) ? String(j.vars.github) : undefined;
    add(`yard:${id}:created`, created, 'wo.created', wo, { goal, stream: 'YARD', alias: id, ...(repo ? { repo } : {}), ...(j.vars?.private === true || j.vars?.private === 'true' ? { private: true } : {}) });
    const status = String(j.status || 'unknown'); const c = closedBy.get(id);
    const hist = Array.isArray(j.history) ? j.history : [];
    const lastAt = isoOrNull(hist[hist.length - 1]?.at) || isoOrNull(j.ended) || c?.at || created;
    const replacedBy = /^J\d+$/.test(String(j.replacedBy || '')) ? String(j.replacedBy) : c?.replacedBy || null;
    const facts = { status, recipe: text(j.recipe, 60) || 'unknown', attempt: Number(j.attempt) || 0, code: archived ? j.code === true : isCode(j), parent: /^J\d+$/.test(String(j.parent || '')) ? String(j.parent) : null,
      archived, ...(c ? { closed: c } : {}), ...(replacedBy ? { replacedBy } : {}) };
    obs(`yard:${id}:status`, hashOf(facts), lastAt, 'x.yard.status', wo, facts);
    const stage = STAGE_OF_STATUS[status];
    if (stage) obs(`yard:${id}:stage`, stage, lastAt, 'stage.entered', wo, { stage });
    else if (c?.proof) obs(`yard:${id}:stage`, 'closed', c.at || lastAt, 'stage.entered', wo, { stage: 'closed' }, `closed as done another way: ${c.proof}`);
    else if (status === 'done' && !facts.code) obs(`yard:${id}:stage`, 'closed', lastAt, 'stage.entered', wo, { stage: 'closed' }, `order finished (${facts.recipe})`);
    if (status === 'quarantined' || status === 'failed') {
      const st = Array.isArray(j.steps) ? j.steps[Math.min(Number(j.cursor) || 0, j.steps.length - 1)] : null;
      obs(`yard:${id}:failed`, `${facts.attempt}:${Number(j.cursor) || 0}:${quarantine.get(id) || ''}`, lastAt, 'step.failed', wo, { step: stepName(st), attempt: clampAttempt(j.attempt), reason: quarantine.get(id) || 'set aside by the Yard', retry: false });
    }
    if (replacedBy && replacedBy !== id) add(`yard:${id}:replaced:${replacedBy}`, c?.at || lastAt, 'replaced', wo, { by: /** @type {string} */ (woOfJob(replacedBy)), reason: c?.reason || `replaced by ${replacedBy}` });
  }

  const dir = path.join(state, 'jobs');
  const files = fs.readdirSync(dir).filter((f) => /^J\d+\.json$/.test(f)).sort((a, b) => Number(a.slice(1, -5)) - Number(b.slice(1, -5)));
  const seen = new Set();
  for (const f of files) {
    const j = readJson(path.join(dir, f));
    if (!j || typeof j !== 'object') { report.unreadable.push(f); continue; }
    let fileAt = now; try { fileAt = fs.statSync(path.join(dir, f)).mtime.toISOString(); } catch { }
    one(j, false, fileAt); seen.add(String(j.id)); report.jobs++;
  }
  for (const a of readJsonl(path.join(dir, 'archive', 'index.jsonl'))) {
    if (!a || seen.has(String(a.id))) continue;
    one({ ...a, history: [] }, true, isoOrNull(a.archivedAt) || now); seen.add(String(a.id)); report.archived++;
  }
  // the Yard itself: paused or running (the PAUSED file), one event per change
  const pausedFile = path.join(state, 'PAUSED'); const paused = fs.existsSync(pausedFile);
  let pausedAt = null; if (paused) { try { pausedAt = isoOrNull(fs.readFileSync(pausedFile, 'utf8').trim()) || fs.statSync(pausedFile).mtime.toISOString(); } catch { } }
  obs('yard:site', paused ? `paused:${pausedAt}` : 'running', pausedAt || now, 'x.yard.site', /** @type {any} */ (null), { paused, pausedAt });
  report.paused = paused;
  return { events, report };
}
