// @ts-check
// Owns the Work tab's API on the Board (lane L5, WO-UPG-L5-1; build-way 3.2 and 4.2, contracts core/contracts/api-*.schema.json):
//   GET  /api/work            the top line, Jordan's Needs-you queue (oldest first, at most 7), streams with WIP, then rows (needs-you
//                             first, then newest; ?page=N, PASS_WORK_PAGE rows a page; X-Rows-Total / X-Rows-Page / X-Rows-Pages headers)
//   GET  /api/work/:id        one work order: its row, events, decisions and brief; ETag = the PR head sha the phone looked at ("none")
//   POST /api/decide          one tap (Yes/Hold/No, A/B/C, + note): exactly one decision.answered event in the ledger's event store
//   GET  /api/work/stream     server-sent events: hello, then card / card-gone / row / top / event as the store moves; Last-Event-ID resumes
// Called by pass-app/server.mjs through its one L5 seam (after the Board's own auth and Origin checks, so a tap needs the same pass key,
// session cookie or Tailscale login as every other Board action), and by pass-app/test-work.mjs.
// Rules kept here:
//   - everything served comes from the ledger's event store (<state>\tide.db, or TIDE_DB) through core/ledger/view.mjs, and everything
//     sent goes through core/ledger/share.mjs (private orders show no words; paths, emails, hosts and private words are removed);
//   - the Work tab is behind the board.work flag (flags.json, then flag.set events); off answers 404 not-found, and nothing else runs;
//   - a tap is bound to the exact card (decision id) and, when the card's order has an open PR, to the head sha the phone was shown
//     (If-Match). A moved PR refuses the tap (412) instead of saying yes to code Jordan did not see. The sha goes in the event's proof;
//   - one decision is answered once: the event's store key is decision.answered:<id>, so two taps that race write one event; the same
//     requestId again answers the first event with duplicate true (a retry is safe), a different one answers already-answered;
//   - nothing is queued: a store that cannot be read or written answers 503 unavailable, never a pretend success.
// node:sqlite needs Node 22.5+ (with --experimental-sqlite on Node 22; no flag on Node 24). Without it the tab reads as off, with the reason.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { flagsNow, WORK_FLAG } from './flags.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(here, '..', '..');

/** The paths this module answers (the server's seam asks this first). @param {string} p */
export const isWorkPath = (p) => p === '/api/decide' || p === '/api/work' || p.startsWith('/api/work/') || p.startsWith('/work/');
/** The Work tab's screen files (pass-app/public/work), served here so a changed file is never answered from an old cache. */
const PUB_WORK = path.resolve(here, '..', 'public', 'work');
const STATIC_TYPES = { '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };

/** core/ is loaded on the first Work request only, so the Board starts and runs as before when the tab is never used. */
/** @type {Promise<any> | null} */ let coreP = null;
function core() {
  coreP ||= Promise.all([
    import('../../core/ledger/store.mjs'), import('../../core/ledger/view.mjs'), import('../../core/ledger/share.mjs'), import('../../core/contracts/validate.mjs'),
  ]).then(([store, view, share, validate]) => ({ ...store, ...view, ...share, validate: validate.validate }));
  return coreP;
}

class WorkError extends Error {
  /** @param {number} status @param {string} code @param {string} message */
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
/** @param {number} s @param {string} c @param {string} m @returns {never} */
const fail = (s, c, m) => { throw new WorkError(s, c, m); };

/**
 * @typedef {{ root: string, send: (res: any, code: number, body: any, type?: string) => void,
 *   readBody: (req: any, max?: number) => Promise<{ body?: any, tooBig?: boolean }>, sec: Record<string, string>,
 *   audit?: (req: any, op: string, body: any, r: any) => void, who?: string }} Ctx
 */

/** Reads a JSON file, or null. @param {string} p */
function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')); } catch { return null; } }
/** The cards, rows and top line of a shared view, to tell what changed later. @param {any} shared @param {number} seq */
const baselineOf = (shared, seq) => ({ seq, cards: new Map(shared.queueAll.map((/** @type {any} */ c) => [c.decision.id, c])), rows: new Map(shared.rows.map((/** @type {any} */ r) => [r.id, r.lastSeq])), top: shared.top });

/** One Work API per state folder: the event store's reader, its one writer of taps, and the open streams. */
export class WorkApi {
  /** @param {{ root: string, db?: string, flagsFile?: string, pollMs?: number, pageSize?: number, maxClients?: number, pingMs?: number, now?: () => Date }} o */
  constructor(o) {
    this.root = o.root;
    this.dbFile = path.resolve(o.db || process.env.TIDE_DB || path.join(o.root, 'tide.db'));
    this.flagsFile = o.flagsFile || path.join(REPO, 'flags.json');
    this.pollMs = Math.max(100, o.pollMs ?? (Number(process.env.PASS_WORK_POLL_MS) || 1000));
    this.pageSize = Math.max(10, Math.min(400, o.pageSize ?? (Number(process.env.PASS_WORK_PAGE) || 100)));
    this.maxClients = o.maxClients ?? 20; this.pingMs = o.pingMs ?? 25000;
    this.now = o.now || (() => new Date());
    /** @type {any} */ this.store = null; /** @type {any[]} */ this.events = []; this.lastSeq = 0;
    /** @type {any} */ this.snap = null;   // { view, shared, priv, redact, flags, builtAt, seq }
    this.offWhy = '';
    /** @type {Set<any>} */ this.clients = new Set();
    /** @type {any} */ this.timer = null; /** @type {any} */ this.pinger = null; /** @type {Promise<void> | null} */ this.ticking = null;
    /** @type {{ seq: number, cards: Map<string, any>, rows: Map<string, number>, top: string } | null} */ this.base = null;
  }

  /** Read new events (only those after lastSeq) and rebuild the view when they moved, or once a minute for the ages. */
  async sync(force = false) {
    const C = await core();
    if (!fs.existsSync(this.dbFile)) { this.reset(); this.offWhy = 'there is no event store yet (the ledger is off until its switch moves; build-way 4.1)'; return null; }
    try {
      if (!this.store) this.store = await C.openStore(this.dbFile, { busyMs: 2000 });
      let more = this.store.events({ afterSeq: this.lastSeq });
      const stale = !more.length && this.snap && Date.now() - this.snap.builtAt > 60000;
      if (stale && this.store.info().lastSeq < this.lastSeq) { this.events = []; this.lastSeq = 0; more = this.store.events({}); }   // the store was built again from the start
      if (more.length) { this.events.push(...more); this.lastSeq = more[more.length - 1].seq; }
      if (more.length || stale || force || !this.snap) this.rebuild(C);
      this.offWhy = '';
      return this.snap;
    } catch (e) {
      const err = /** @type {any} */ (e); this.reset();
      this.offWhy = `the event store cannot be read (${err.code || 'error'}: ${String(err.message || err).slice(0, 160)})`;
      return null;
    }
  }
  reset() { try { this.store?.close(); } catch { } this.store = null; this.events = []; this.lastSeq = 0; this.snap = null; }

  /** The view over every event, shared through share.mjs. @param {any} C */
  rebuild(C) {
    const view = C.buildView(this.events, { now: this.now(), flagDefaults: readJson(this.flagsFile) });
    const priv = C.privateOf(view);
    const pw = C.readPrivateWords(path.join(this.root, C.PRIVATE_WORDS_FILE));
    const redact = C.makeRedactor({ privateWords: [...pw.words, ...priv.words] });
    const { internal, ...work } = view;
    const shared = C.shareWork(work, priv, redact);
    this.snap = { view, shared, priv, redact, flags: flagsNow({ events: this.events, flagsFile: this.flagsFile }), builtAt: Date.now(), seq: this.lastSeq };
  }

  /** The shared form of one event (private orders and x.* kinds lose their data; every string is redacted). @param {any} C @param {any} e */
  pubEvent(C, e) { return C.redactDeep(C.publicEvent(e, { private: this.snap.priv.ids.has(e.wo) }).doc, this.snap.redact); }

  /** The open PR head a card's order is at now, or null. @param {string | null} wo */
  headOf(wo) {
    const w = wo ? this.snap.view.internal.fold.wos.get(wo) : null;
    return w && w.pr && !w.prClosed && w.head ? { pr: String(w.pr), head: String(w.head) } : null;
  }

  /** Gate every request: the store is readable and board.work is on. */
  async ready() {
    const s = await this.sync();
    if (!s) fail(404, 'not-found', `The Work tab is off: ${this.offWhy}.`);
    if (!s.flags.on(WORK_FLAG)) fail(404, 'not-found', `The Work tab is off (flag ${WORK_FLAG}; turning it on is Jordan's card).`);
    return s;
  }

  /** GET /api/work @param {URL} url @param {any} res */
  async work(url, res) {
    const s = await this.ready(); const size = this.pageSize;
    const rows = s.shared.rows; const pages = Math.max(1, Math.ceil(rows.length / size));
    const page = Math.min(pages, Math.max(1, Math.floor(Number(url.searchParams.get('page')) || 1)));
    res.setHeader('X-Rows-Total', String(rows.length)); res.setHeader('X-Rows-Page', String(page)); res.setHeader('X-Rows-Pages', String(pages));
    res.setHeader('X-Work-Seq', String(s.seq));
    return { ok: true, at: s.shared.at, top: s.shared.top, queue: s.shared.queue, queueTotal: s.shared.queueTotal, streams: s.shared.streams.slice(0, 50),
      rows: rows.slice((page - 1) * size, page * size), flags: s.shared.flags };
  }

  /** GET /api/work/:id @param {string} id @param {any} res */
  async item(id, res) {
    const C = await core(); const s = await this.ready();
    const wo = /^J\d+$/.test(id) ? `WO-${id.slice(1)}` : id;
    if (!/^WO-[A-Z0-9]+(-[A-Z0-9]+)*$/.test(wo)) fail(400, 'bad-request', 'A work order id looks like WO-312 or J312.');
    const row = s.shared.rows.find((/** @type {any} */ r) => r.id === wo);
    if (!row) fail(404, 'not-found', `No work order ${wo} in the ledger.`);
    const priv = s.priv.ids.has(wo);
    // a private order's events keep no data, which their kinds' contract shapes need, so none are sent (its row still shows where it is)
    const evs = priv ? [] : this.events.filter((e) => e.wo === wo).map((e) => this.pubEvent(C, e));
    const decisions = [...s.view.internal.fold.decisions.values()].filter((d) => d.wo === wo).sort((a, b) => String(a.at).localeCompare(String(b.at)) || String(a.id).localeCompare(String(b.id)))
      .map((d) => C.redactDeep(priv ? masked(decisionOut(d)) : decisionOut(d), s.redact));
    const h = this.headOf(wo); res.setHeader('ETag', `"${h ? h.head : 'none'}"`);
    return { ok: true, row, events: evs, decisions, brief: row.brief, report: null };
  }

  /** POST /api/decide: check the tap, then write it. @param {any} req @param {Ctx} ctx */
  async decide(req, ctx) {
    const C = await core();
    if (req.method !== 'POST') fail(405, 'bad-request', 'POST only.');
    if (!String(req.headers['content-type'] || '').toLowerCase().startsWith('application/json')) fail(415, 'bad-request', 'JSON only.');
    const { body, tooBig } = await ctx.readBody(req, 8192);
    if (tooBig) fail(413, 'bad-request', 'The tap is too large (the note is at most 2000 characters).');
    const v = C.validate('api-decide', body);
    if (!v.ok) fail(400, 'bad-request', `The tap is not well formed: ${String(v.errors[0] || '').slice(0, 200)}`);
    const s = await this.ready();
    const d = s.view.internal.fold.decisions.get(body.decision);
    if (!d) fail(404, 'unknown-card', `There is no card ${body.decision}.`);
    const prior = this.answeredEvent(body.decision);
    if (prior) return this.replay(C, prior, body);
    if (!Array.isArray(d.options) || !d.options.includes(body.answer)) fail(400, 'bad-answer', `${body.answer} is not one of this card's answers (${(d.options || []).join(', ')}).`);
    if (!d.wo) fail(400, 'bad-request', `Card ${d.id} names no work order, so its answer cannot be recorded.`);
    return this.write(C, d, body, this.boundHead(d, req.headers['if-match']));
  }

  /** The tap is bound to the exact PR head the phone was shown: returns that head (or null), or refuses. @param {any} d @param {unknown} header */
  boundHead(d, header) {
    const h = this.headOf(d.wo); const seen = ifMatch(header);
    if (h && !seen) fail(428, 'bad-request', `Card ${d.id} is about ${h.pr} at ${h.head.slice(0, 7)}: open the card again, then tap (the tap must name the head you looked at).`);
    if (h && seen !== h.head) fail(412, 'bad-request', `${h.pr} moved to ${h.head.slice(0, 7)} after you looked${seen && seen !== 'none' ? ` at ${seen.slice(0, 7)}` : ''}: look again, then tap.`);
    if (!h && seen && seen !== 'none') fail(412, 'bad-request', `Card ${d.id}'s order has no open PR any more: look again, then tap.`);
    return h;
  }

  /** Write one decision.answered event (once per card: its store key). @param {any} C @param {any} d @param {any} body @param {{ pr: string, head: string } | null} h */
  async write(C, d, body, h) {
    const ev = { at: this.now().toISOString(), actor: 'jordan', kind: 'decision.answered', wo: d.wo,
      data: { decision: d.id, answer: body.answer, note: body.note ?? null, via: body.via, requestId: body.requestId },
      proof: h ? `${h.pr} head ${h.head}` : null, key: `decision.answered:${d.id}` };
    let added = 0;
    try { added = this.store.append([ev]).added; } catch (e) { fail(503, 'unavailable', `The tap was NOT recorded: the event store refused the write (${/** @type {any} */ (e).code || 'error'}). Try again.`); }
    await this.sync(true);
    const stored = this.answeredEvent(d.id);
    if (!stored) fail(503, 'unavailable', 'The tap was NOT recorded: it is not in the event store after the write. Try again.');
    if (!added) return this.replay(C, stored, body);   // another tap on the same card won the race
    this.tick();   // phones see the card go now, not on the next poll
    return { ok: true, event: this.pubEvent(C, stored), duplicate: false };
  }
  /** @param {string} id */
  answeredEvent(id) { return this.events.find((e) => e.kind === 'decision.answered' && e.data?.decision === id) || null; }
  /** @param {any} C @param {any} prior @param {any} body */
  replay(C, prior, body) {
    if (prior.data?.requestId && prior.data.requestId === body.requestId) return { ok: true, event: this.pubEvent(C, prior), duplicate: true };
    return fail(409, 'already-answered', `Card ${body.decision} was already answered (${prior.data?.answer}, ${prior.at}).`);
  }

  // ---- GET /api/work/stream (SSE) ----
  /** @param {any} res @param {string} type @param {any} data */
  msg(res, type, data) {
    const seq = this.snap ? this.snap.seq : 0;
    try { res.write(`id: ${seq}\nevent: ${type}\ndata: ${JSON.stringify({ type, at: this.now().toISOString(), seq, data })}\n\n`); } catch { }
  }
  /** What changed since `from` (a baseline), as stream messages. @param {any} C @param {number} afterSeq @param {any} from */
  changes(C, afterSeq, from) {
    const snap = this.snap; /** @type {Array<[string, any]>} */ const out = [];
    for (const e of this.events) if (e.seq > afterSeq) out.push(['event', this.pubEvent(C, e)]);
    const cardsNow = new Map(snap.shared.queueAll.map((/** @type {any} */ c) => [c.decision.id, c]));
    for (const [id, c] of cardsNow) if (!from.cards.has(id)) out.push(['card', c]);
    for (const id of from.cards.keys()) if (!cardsNow.has(id)) { const a = snap.view.internal.fold.decisions.get(id)?.answer; out.push(['card-gone', { decision: id, ...(a ? { answer: String(a) } : {}) }]); }
    for (const r of snap.shared.rows) if (from.rows.get(r.id) !== r.lastSeq) out.push(['row', r]);
    if (snap.shared.top !== from.top) out.push(['top', { top: snap.shared.top }]);
    return out;
  }
  /** One tick at a time, so two ticks never send the same change twice. */
  tick() { if (!this.ticking) this.ticking = this.step().catch(() => { }).finally(() => { this.ticking = null; }); return this.ticking; }
  async step() {
    if (!this.clients.size) return;
    const before = this.base; const s = await this.sync();
    // the store went away or the tab was turned off: the streams end; phones reconnect and read why
    if (!s || !s.flags.on(WORK_FLAG)) { for (const c of [...this.clients]) this.drop(c); return; }
    if (!before || (s.seq === before.seq && s.shared.top === before.top)) { this.base = baselineOf(s.shared, s.seq); return; }
    const out = this.changes(await core(), before.seq, before);
    this.base = baselineOf(s.shared, s.seq);
    for (const c of this.clients) for (const [t, d] of out) this.msg(c, t, d);
  }
  /** @param {any} res */
  drop(res) { this.clients.delete(res); try { res.end(); } catch { } if (!this.clients.size) this.stopTimers(); }
  stopTimers() { if (this.timer) clearInterval(this.timer); if (this.pinger) clearInterval(this.pinger); this.timer = this.pinger = null; }
  /** GET /api/work/stream @param {any} req @param {any} res @param {URL} url @param {Ctx} ctx */
  async stream(req, res, url, ctx) {
    const C = await core(); const s = await this.ready();
    while (this.clients.size >= this.maxClients) this.drop(this.clients.values().next().value);
    const raw = req.headers['last-event-id'] ?? url.searchParams.get('last');
    const last = raw == null || raw === '' ? NaN : Number(raw);
    // resume only from a seq this store has (a rebuilt store starts again at 1) and only when the gap is small; else the phone reloads
    const missed = Number.isInteger(last) && last >= 0 && last <= s.seq ? this.events.filter((e) => e.seq > last) : null;
    const resumed = !!missed && missed.length <= 500;
    res.writeHead(200, { ...ctx.sec, 'Content-Type': 'text/event-stream', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
    res.write('retry: 1500\n\n');
    this.msg(res, 'hello', { queueTotal: s.shared.queueTotal, resumed });
    if (resumed) {
      // the cards and rows as they stood at `last`, rebuilt from the events up to it, so the phone gets exactly what it missed
      const then = C.buildView(this.events.filter((e) => e.seq <= last), { now: this.now(), flagDefaults: readJson(this.flagsFile) });
      const thenShared = C.shareWork((({ internal, ...w }) => w)(then), C.privateOf(then), s.redact);
      for (const [t, d] of this.changes(C, last, baselineOf(thenShared, last))) this.msg(res, t, d);
    }
    await this.tick();   // the phones already here get what moved first, so the new phone starts from the same baseline
    if (!this.base || !this.clients.size) this.base = baselineOf(this.snap.shared, this.snap.seq);
    this.clients.add(res);
    const bye = () => { this.clients.delete(res); if (!this.clients.size) this.stopTimers(); };
    req.on('close', bye); res.on('close', bye);
    if (!this.timer) { this.timer = setInterval(() => this.tick(), this.pollMs); this.timer.unref?.(); }
    if (!this.pinger) { this.pinger = setInterval(() => { for (const c of this.clients) this.msg(c, 'ping', {}); }, this.pingMs); this.pinger.unref?.(); }
  }

  /**
   * The seam's one call. Answers every /api/work* and /api/decide request; errors are the contract's apiError.
   * @param {any} req @param {any} res @param {URL} url @param {Ctx} ctx
   */
  async handle(req, res, url, ctx) {
    const p = url.pathname;
    try {
      if (p === '/api/decide') {
        const r = await this.decide(req, ctx).catch((e) => { ctx.audit?.(req, 'work-decide', { id: '' }, { ok: false, error: e.code || 'error' }); throw e; });
        ctx.audit?.(req, 'work-decide', { id: r.event?.data?.decision || '' }, r);
        return ctx.send(res, 200, r);
      }
      if (req.method !== 'GET' && req.method !== 'HEAD') fail(405, 'bad-request', 'GET only.');
      if (p === '/api/work') return ctx.send(res, 200, await this.work(url, res));
      if (p.startsWith('/work/')) return this.file(p, res, ctx);
      if (p === '/api/work/stream') return await this.stream(req, res, url, ctx);
      if (p === '/api/work/events') return ctx.send(res, 200, await this.week(url));
      let id = ''; try { id = decodeURIComponent(p.slice('/api/work/'.length)); } catch { fail(400, 'bad-request', 'A work order id looks like WO-312 or J312.'); }
      return ctx.send(res, 200, await this.item(id, res));
    } catch (e) {
      const err = /** @type {any} */ (e);
      if (res.headersSent) { try { res.end(); } catch { } return; }
      if (err instanceof WorkError) return ctx.send(res, err.status, { ok: false, code: err.code, error: err.message });
      console.error('work api:', p, err?.message);
      return ctx.send(res, 503, { ok: false, code: 'unavailable', error: 'The Work tab hit an error; nothing was recorded. Try again.' });
    }
  }

  /**
   * GET /api/work/events?days=7: the events of the last days (at most 14), newest 3000, shared like every other answer, for the
   * Work tab's week replay. Not in the contracts yet (a card asks for it); each item is an event contract object.
   * @param {URL} url
   */
  async week(url) {
    const C = await core(); await this.ready();
    const days = Math.min(14, Math.max(1, Math.floor(Number(url.searchParams.get('days')) || 7)));
    const from = new Date(this.now().getTime() - days * 86400e3).toISOString();
    const list = this.events.filter((e) => String(e.at) >= from).slice(-3000).map((e) => this.pubEvent(C, e));
    return { ok: true, at: this.now().toISOString(), from, events: list };
  }

  /** One file of pass-app/public/work (.js, .css, .svg only), read fresh and never cached by the browser. @param {string} p @param {any} res @param {Ctx} ctx */
  file(p, res, ctx) {
    let rel = ''; try { rel = decodeURIComponent(p.slice('/work/'.length)); } catch { }
    const full = path.resolve(PUB_WORK, rel); const type = STATIC_TYPES[/** @type {keyof typeof STATIC_TYPES} */ (path.extname(full))];
    if (!rel || !type || !full.startsWith(PUB_WORK + path.sep) || !fs.existsSync(full) || !fs.statSync(full).isFile()) return ctx.send(res, 404, { ok: false, code: 'not-found', error: 'not found' });
    return ctx.send(res, 200, fs.readFileSync(full), type);
  }

  close() { for (const c of [...this.clients]) this.drop(c); this.stopTimers(); this.reset(); }
}

/** A decision as the contract shapes it (the same fields view.mjs gives the queue). @param {any} d */
function decisionOut(d) {
  return { v: '1.0', id: d.id, wo: d.wo ?? null, kind: d.kind, ask: d.ask, options: d.options, recommended: d.recommended, ...(d.why !== undefined ? { why: d.why } : {}),
    ...(d.variants ? { variants: d.variants } : {}), answer: d.answer ?? null, note: d.note ?? null, at: d.at, answeredAt: d.answeredAt ?? null, via: d.via ?? null,
    ...(d.standing !== undefined ? { standing: d.standing } : {}) };
}
/** A private order's decision: no words (as share.mjs masks the queue). @param {any} d */
const masked = (d) => ({ ...d, ask: 'a private question', ...(d.why != null ? { why: null } : {}), note: d.note == null ? null : '(private)', ...(d.variants ? { variants: d.variants.map((/** @type {any} */ x) => ({ ...x, title: 'a private work order' })) } : {}) });

/** The sha in an If-Match header ("abc1234", W/"abc1234" or abc1234), lower case, or null. @param {unknown} h */
function ifMatch(h) {
  const m = /^\s*(?:W\/)?"?([0-9a-fA-F]{7,40}|none)"?\s*$/.exec(String(h ?? ''));
  return m ? m[1].toLowerCase() : null;
}

/** @type {Map<string, WorkApi>} */ const apis = new Map();
/**
 * The server seam: one Work API per state folder, made on first use.
 * @param {any} req @param {any} res @param {URL} url @param {Ctx} ctx
 */
export function workRoute(req, res, url, ctx) {
  let api = apis.get(ctx.root); if (!api) { api = new WorkApi({ root: ctx.root }); apis.set(ctx.root, api); }
  return api.handle(req, res, url, ctx);
}
