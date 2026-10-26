// @ts-check
// The ledger commands behind cli.mjs: build (import every source into the event store, then write the view and the ledger.json export),
// show, queue, streams, parity, flags, backup. Writes only the --db file and the --out folder; never the live state folder while the
// ledger's upgrade switch is "old" (the shadow cutover is Jordan's card).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openStore, StoreError } from './store.mjs';
import { importYard } from './import-yard.mjs';
import { importGithub } from './import-github.mjs';
import { importLocal } from './import-local.mjs';
import { buildView, exportLedgerJson } from './view.mjs';
import { compareLedgers } from './parity.mjs';
import { readSwitches } from '../contracts/upgrade.mjs';
import { woOfJob } from './ids.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(here, '..', '..');

class UsageError extends Error { }

/** @param {string[]} argv */
export function parseArgs(argv) {
  const o = /** @type {any} */ ({ _: [], repo: [] });
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { o._.push(a); continue; }
    const k = a.slice(2);
    if (['json', 'no-github'].includes(k)) { o[k] = true; continue; }
    const v = argv[++i]; if (v === undefined) throw new UsageError(`--${k} needs a value`);
    if (k === 'repo') o.repo.push(v); else o[k] = v;
  }
  return o;
}

/** The live state folder (the Yard's own); a write into it needs the ledger switch past "old". */
export function liveStateDir() { return path.resolve(process.env.LEDGER_LIVE_STATE || path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'brain-kitchen')); }
/** @param {string} p @param {string} dir */
const inside = (p, dir) => { const r = path.relative(dir, path.resolve(p)); return r === '' || (!r.startsWith('..') && !path.isAbsolute(r)); };

/** Refuse a write into the live state folder while the switch is old. @param {string[]} targets */
export function guardLive(targets) {
  const live = liveStateDir();
  if (!targets.some((t) => inside(t, live))) return;
  let sw = 'old';
  for (const f of [path.join(live, 'kitchen.json'), path.join(REPO_ROOT, 'kitchen', 'kitchen.json')]) {
    if (fs.existsSync(f)) { sw = readSwitches(f).switches.ledger; break; }   // an unreadable file reads as all old (upgrade.mjs)
  }
  if (sw === 'old') throw new UsageError(`refused: ${targets.join(', ')} is inside the live state folder and the ledger switch is "old"; use a scratch copy (moving the switch to shadow is Jordan's card)`);
}

/** @param {string} p */
function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')); } catch { return null; } }
/** @param {string} p @param {unknown} obj */
function writeAtomic(p, obj) { fs.mkdirSync(path.dirname(p), { recursive: true }); const t = `${p}.tmp-${process.pid}`; fs.writeFileSync(t, JSON.stringify(obj, null, 1)); fs.renameSync(t, p); }
/** @param {any} o */
const nowOf = (o) => { if (!o.now) return new Date(); const d = new Date(o.now); if (Number.isNaN(d.getTime())) throw new UsageError('--now must be a time like 2030-01-07T09:00:00Z'); return d; };
const flagsFile = (/** @type {any} */ o) => o.flags || path.join(REPO_ROOT, 'flags.json');

/** @param {any} o */
async function viewFrom(o) {
  if (!o.db) throw new UsageError('give --db <file> (the event store)');
  const store = await openStore(o.db, { readOnly: true });
  try { const events = store.events(); return { events, view: buildView(events, { now: nowOf(o), flagDefaults: readJson(flagsFile(o)) }) }; } finally { store.close(); }
}

/** @param {any} o @param {(s: string) => void} say */
async function build(o, say) {
  if (!o.state) throw new UsageError('give --state <dir> (a scratch copy of the state folder)');
  if (!o.db) throw new UsageError('give --db <file> (the shadow event store, for example <scratch>\\tide.db)');
  const out = path.resolve(o.out || path.dirname(path.resolve(o.db)));
  guardLive([o.db, out]);
  const now = nowOf(o);
  const store = await openStore(o.db);
  const report = /** @type {any} */ ({ added: {} });
  try {
    const y = importYard(o.state, { now }); report.yard = y.report; report.added.yard = store.append(y.events).added;
    if (!o['no-github']) {
      const cache = readJson(path.join(o.state, 'towers-github.json'));
      const repos = o.github ? String(o.github).split(',').map((s) => s.trim()).filter(Boolean) : Object.keys(cache?.repos || {});
      const g = importGithub({ repos, state: o.state, out, now }); report.github = g.report; report.added.github = store.append(g.events).added;
    } else report.github = { state: 'skipped (--no-github)' };
    const repos = (o.repo.length ? o.repo : [`tide=${REPO_ROOT}`]).map((/** @type {string} */ s) => { const i = s.indexOf('='); if (i < 1) throw new UsageError(`--repo is name=path, not ${s}`); return { name: s.slice(0, i), path: s.slice(i + 1) }; });
    const l = importLocal({ repos, plans: o.plans, work: o.work, now }); report.local = l.report; report.added.local = store.append(l.events).added;
    const events = store.events();
    const view = buildView(events, { now, flagDefaults: readJson(flagsFile(o)) });
    const { internal, ...work } = view;
    writeAtomic(path.join(out, 'work.json'), { ok: true, ...work });
    writeAtomic(path.join(out, 'ledger.next.json'), exportLedgerJson(view));
    report.store = store.info(); report.top = view.top; report.rows = view.rows.length;
    say(view.top);
    say(`events: ${report.store.events} (added: yard ${report.added.yard}, github ${report.added.github ?? 0}, local ${report.added.local}); rows ${view.rows.length}; wrote ${path.join(out, 'work.json')} and ledger.next.json`);
    if (report.github?.state && report.github.state !== 'ok') say(`GitHub: ${report.github.state}${report.github.lastGoodAt ? ` (last good read ${report.github.lastGoodAt})` : ''}`);
    return report;
  } finally { store.close(); }
}

/**
 * @param {string[]} argv
 * @param {{ out?: (s: string) => void }} [io]
 * @returns {Promise<number>}
 */
export async function main(argv, io = {}) {
  const say = io.out || ((/** @type {string} */ s) => process.stdout.write(s + '\n'));
  let o = /** @type {any} */ ({ _: [] });
  try {
    o = parseArgs(argv);
    const cmd = o._[0] || 'build';
    const emit = (/** @type {any} */ obj, /** @type {() => void} */ text) => { if (o.json) say(JSON.stringify(obj)); else text(); };
    if (cmd === 'build') { const r = await build(o, o.json ? () => { } : say); if (o.json) say(JSON.stringify({ ok: true, ...r })); return 0; }
    if (cmd === 'show') {
      const id = String(o._[1] || ''); if (!id) throw new UsageError('give an id: show WO-312 (or J312)');
      const { events, view } = await viewFrom(o); const wo = /^J\d+$/.test(id) ? woOfJob(id) : id;
      const row = view.rows.find((r) => r.id === wo || r.alias === id);
      if (!row) { emit({ ok: false, code: 'not-found', error: `nothing named ${id} in the ledger` }, () => say(`nothing named ${id} in the ledger`)); return 1; }
      const evs = events.filter((e) => e.wo === row.id);
      emit({ ok: true, row, events: evs }, () => {
        say(`${row.id}${row.alias ? ` (${row.alias})` : ''} [${row.stream}] ${row.goal.slice(0, 120)}`);
        say(`  ${row.state} at ${row.stage} for ${row.stageAgeH} h (age ${row.ageH} h); owner ${row.owner}${row.blockedOn ? `; waits on: ${row.blockedOn}` : ''}`);
        if (row.next) say(`  next: ${row.next}`); if (row.proof) say(`  proof: ${row.proof}`); if (row.pr) say(`  ${row.pr} ${row.branch} -> ${row.base}${row.stackParent ? ` (stacked on ${row.stackParent})` : ''}`);
        if (row.plan) say(`  plan: ${row.plan}`);
        for (const e of evs) say(`  #${e.seq} ${e.at} ${e.kind} by ${e.actor}${e.proof ? ` proof: ${e.proof}` : ''}`);
      });
      return 0;
    }
    if (cmd === 'queue') {
      const { view } = await viewFrom(o);
      const waiting = view.rows.filter((r) => r.state === 'waiting-on-jordan' && !r.decision).sort((a, b) => b.stageAgeH - a.stageAgeH);
      emit({ ok: true, queue: view.queueAll, queueTotal: view.queueTotal, waitingWithoutCard: waiting }, () => {
        say(`${view.queueTotal} cards for Jordan, oldest first; ${waiting.length} orders wait on him with no card`);
        view.queueAll.forEach((c, i) => say(`${i + 1}. [${c.ageH} h] ${c.decision.id} ${c.decision.kind}: ${c.decision.ask} (recommended: ${c.decision.recommended})`));
        for (const r of waiting) say(`-  [${r.stageAgeH} h] ${r.id}: ${r.blockedOn} (no card)`);
      });
      return 0;
    }
    if (cmd === 'streams') {
      const { view } = await viewFrom(o);
      emit({ ok: true, streams: view.streams, flags: view.flags }, () => {
        say(view.top);
        for (const s of view.streams) say(`${s.stream}: ${s.open} open, oldest ${s.oldestH} h at ${s.stage ?? '-'}, ${s.cards} waiting on Jordan${s.overLimit ? ' (OVER A LIMIT)' : ''}${s.blockedOn ? `; ${s.blockedOn}` : ''}`);
        for (const f of view.flags.filter((x) => x.flag === 'over-wip' || x.flag === 'stack-too-deep')) say(`! ${f.detail}`);
      });
      return 0;
    }
    if (cmd === 'flags') { const { view } = await viewFrom(o); emit({ ok: true, flags: view.flagValues }, () => { if (!view.flagValues.length) say('no feature flags declared or set'); for (const f of view.flagValues) say(`${f.flag}: ${f.on ? 'on' : 'off'} (${f.from}${f.decision ? `, ${f.decision}` : ''})`); }); return 0; }
    if (cmd === 'parity') {
      if (!o.old) throw new UsageError('give --old <ledger.json> (built by kitchen/ledger.ps1 on the same scratch copy)');
      const old = readJson(o.old); if (!old) { emit({ ok: false, code: 'unreadable', error: `cannot read ${o.old}` }, () => say(`cannot read ${o.old}`)); return 1; }
      const { events, view } = await viewFrom(o); const p = compareLedgers(old, view, events);
      emit(p, () => {
        say(`Parity: ${p.old} old items: ${p.same} same, ${p.explained} explained, ${p.unexplained} unexplained; ${p.newOnly} rows only in the new ledger; ${p.lobeFlagsNotImported} lobe flags not imported`);
        for (const i of p.items.filter((x) => x.verdict !== 'same')) say(`${i.verdict === 'unexplained' ? 'UNEXPLAINED' : 'explained'} ${i.old} (${i.oldState}) -> ${i.new ?? 'no row'} (${i.newState ?? '-'}): ${i.reason}`);
        for (const [k, n] of Object.entries(p.newOnlyWhy)) say(`new only: ${n} x ${k}`);
      });
      return p.ok ? 0 : 3;
    }
    if (cmd === 'backup') {
      if (!o.db || !o.to) throw new UsageError('give --db <file> --to <file>');
      guardLive([o.to]);
      const store = await openStore(o.db, { readOnly: true }); try { store.backup(o.to); } finally { store.close(); }
      emit({ ok: true, to: o.to }, () => say(`copied to ${o.to}`)); return 0;
    }
    throw new UsageError(`unknown command '${cmd}' (build, show, queue, streams, parity, flags, backup)`);
  } catch (e) {
    const usage = e instanceof UsageError; const code = e instanceof StoreError ? e.code : usage ? 'usage' : 'error';
    const msg = String(/** @type {any} */ (e)?.message || e);
    if (o.json) say(JSON.stringify({ ok: false, code, error: msg })); else say(`ERROR (${code}): ${msg}`);
    return usage ? 2 : 1;
  }
}
