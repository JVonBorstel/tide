// @ts-check
// The record of truth: an append-only event log in SQLite (build-way 2.2 and 3.1, contract core/contracts/event.schema.json).
// This file is the only one that touches node:sqlite, so better-sqlite3 (the runner-up, build-way 10.1) can be swapped in here alone.
// node:sqlite is built into Node 22.5+ (behind --experimental-sqlite on 22; cli.mjs adds the flag only when needed) and Node 24.
// Rules kept here, not by callers:
//   - events are only ever appended: triggers refuse every UPDATE, DELETE and REPLACE of an event (recursive_triggers is on, so a
//     REPLACE's delete fires the delete trigger), and the store hands out no raw SQL; only append and reads;
//   - every event is checked against the event contract before it is written; one bad event writes nothing (one transaction);
//   - two ways to make a rerun add 0 events:
//       key: a one-time fact (an order was created, a PR merged): an event whose key is stored is skipped;
//       family + value: an observation that can change and change back (a stage, a CI result, paused or not): the event is written only
//       when its value differs from the family's last stored value, so A -> B -> A records all three changes, and A, A records one;
//   - WAL journal, STRICT tables, a schema version (PRAGMA user_version), one writer (the Node core).
// Errors carry a code a program can act on: unavailable, missing, corrupt, locked, newer-schema, bad-event, append-only, exists.
import fs from 'node:fs';
import path from 'node:path';
import { validate } from '../contracts/validate.mjs';

export const SCHEMA_VERSION = 2;
/** The event contract version this code writes (common.schema.json version: 1.x). */
export const CONTRACT_V = '1.0';

export class StoreError extends Error {
  /** @param {string} code @param {string} message */
  constructor(code, message) { super(message); this.code = code; }
}

/** node:sqlite needs Node 22.5 or later. @param {string} [v] */
export function nodeHasSqlite(v = process.versions.node) { const [a, b] = v.split('.').map(Number); return a > 22 || (a === 22 && b >= 5); }

/** @returns {Promise<any>} the node:sqlite module, or a StoreError('unavailable') in plain words */
export async function sqliteModule() {
  try { return await import('node:sqlite'); } catch {
    throw new StoreError('unavailable', nodeHasSqlite() ? `node:sqlite is not available in Node ${process.versions.node} (Node 22 needs --experimental-sqlite; run through core/ledger/cli.mjs, which adds it)`
      : `the ledger needs Node 22.5 or later for node:sqlite; this is Node ${process.versions.node}`);
  }
}

const DDL = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  v TEXT NOT NULL,
  at TEXT NOT NULL,
  actor TEXT NOT NULL,
  kind TEXT NOT NULL,
  wo TEXT,
  data TEXT NOT NULL,
  proof TEXT,
  source_key TEXT UNIQUE,
  family TEXT,
  value TEXT
) STRICT;`;
const DDL_AFTER = `
CREATE INDEX IF NOT EXISTS events_wo ON events (wo, seq);
CREATE INDEX IF NOT EXISTS events_kind ON events (kind, seq);
CREATE INDEX IF NOT EXISTS events_family ON events (family, seq);
CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'events are append-only: an event is never changed'); END;
CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'events are append-only: an event is never deleted'); END;
CREATE TRIGGER IF NOT EXISTS events_no_replace BEFORE INSERT ON events BEGIN
  SELECT RAISE(ABORT, 'events are append-only: an event is never replaced') WHERE NEW.seq IS NOT NULL AND EXISTS (SELECT 1 FROM events WHERE seq = NEW.seq);
  SELECT RAISE(IGNORE) WHERE NEW.source_key IS NOT NULL AND EXISTS (SELECT 1 FROM events WHERE source_key = NEW.source_key);
END;`;

/** @param {unknown} e */
function classify(e) {
  const m = String(/** @type {any} */ (e)?.message || e);
  if (e instanceof StoreError) return e;
  if (/not a database|malformed|file is encrypted|disk image/i.test(m)) return new StoreError('corrupt', `the event store file is damaged (${m.slice(0, 120)}); restore the nightly copy (VACUUM INTO) or build a new one from the sources`);
  if (/locked|busy/i.test(m)) return new StoreError('locked', `the event store is locked by another writer (${m.slice(0, 120)}); there is one writer, so try again when it is done`);
  if (/append-only/.test(m)) return new StoreError('append-only', m.replace(/^.*?(events are append-only)/, '$1'));
  return new StoreError('error', m.slice(0, 300));
}

/**
 * Open (or create) the store.
 * @param {string} file the database path (":memory:" for tests)
 * @param {{ readOnly?: boolean, busyMs?: number }} [opt]
 */
export async function openStore(file, opt = {}) {
  const { DatabaseSync } = await sqliteModule();
  if (file !== ':memory:') {
    if (opt.readOnly && !fs.existsSync(file)) throw new StoreError('missing', `no event store at ${file} yet (run: node core/ledger/cli.mjs build)`);
    if (!opt.readOnly) fs.mkdirSync(path.dirname(path.resolve(file)), { recursive: true });
  }
  let db;
  try {
    db = new DatabaseSync(file, opt.readOnly ? { readOnly: true } : {});
    db.exec(`PRAGMA busy_timeout = ${Math.max(0, opt.busyMs ?? 2000)}`);
    db.exec('PRAGMA recursive_triggers = ON');   // a REPLACE's implied delete fires events_no_delete
    const ver = Number(db.prepare('PRAGMA user_version').get()?.user_version ?? 0);
    if (ver > SCHEMA_VERSION) throw new StoreError('newer-schema', `the event store is schema ${ver}, newer than this code (${SCHEMA_VERSION}); update the code, never the file`);
    if (!opt.readOnly) {
      if (file !== ':memory:') db.exec('PRAGMA journal_mode = WAL');
      db.exec(DDL);
      if (ver === 1) { db.exec('ALTER TABLE events ADD COLUMN family TEXT'); db.exec('ALTER TABLE events ADD COLUMN value TEXT'); }   // schema 1 -> 2: observation families
      db.exec(DDL_AFTER);
      if (ver < SCHEMA_VERSION) db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
    } else if (ver === 0) throw new StoreError('corrupt', 'the file has no event store schema (user_version 0)');
    else if (ver < SCHEMA_VERSION) throw new StoreError('older-schema', `the event store is schema ${ver}; open it once for writing (cli.mjs build) to bring it to ${SCHEMA_VERSION}`);
  } catch (e) { try { db?.close(); } catch { } throw classify(e); }
  return new Store(db, file);
}

/** @typedef {{ v?: string, seq?: number, at: string, actor: string, kind: string, wo: string | null, data: object, proof: string | null }} Event */
/** @typedef {Event & { key?: string, family?: string, value?: string }} NewEvent */

export class Store {
  /** @type {any} */ #db;
  /** @param {any} db @param {string} file */
  constructor(db, file) { this.#db = db; this.file = file; }

  /** @returns {{ version: number, journal: string, events: number, lastSeq: number, strict: boolean, triggers: string[] }} */
  info() {
    try {
      const version = Number(this.#db.prepare('PRAGMA user_version').get().user_version);
      const journal = String(this.#db.prepare('PRAGMA journal_mode').get().journal_mode);
      const r = this.#db.prepare('SELECT COUNT(*) AS n, COALESCE(MAX(seq), 0) AS last FROM events').get();
      const tables = this.#db.prepare("SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name IN ('events', 'meta')").all();
      const triggers = this.#db.prepare("SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name").all().map((/** @type {any} */ t) => String(t.name));
      return { version, journal, events: Number(r.n), lastSeq: Number(r.last), strict: tables.length === 2 && tables.every((/** @type {any} */ t) => /\)\s*STRICT\s*$/.test(t.sql)), triggers };
    } catch (e) { throw classify(e); }
  }

  /** The last stored value of an observation family, or null (importers use it to tell a change from a first sight). @param {string} family */
  lastValue(family) {
    try { const r = this.#db.prepare('SELECT value FROM events WHERE family = ? ORDER BY seq DESC LIMIT 1').get(family); return r ? String(r.value) : null; } catch (e) { throw classify(e); }
  }

  /**
   * Append events (all or none). An event with a `key` is skipped when that key is stored; an event with a `family` and `value` is skipped
   * when the family's last value (stored, or earlier in this batch) is the same.
   * @param {NewEvent[]} events
   * @returns {{ added: number, skipped: number, lastSeq: number }}
   */
  append(events) {
    for (const [i, ev] of events.entries()) {
      const { key, family, value, seq, ...body } = /** @type {any} */ (ev);
      if ((family === undefined) !== (value === undefined)) throw new StoreError('bad-event', `event ${i + 1} (${body.kind}) has a family without a value, or a value without a family`);
      const r = validate('event', { v: CONTRACT_V, seq: 1, ...body });
      if (!r.ok) throw new StoreError('bad-event', `event ${i + 1} (${body.kind} ${body.wo ?? ''}) breaks the event contract: ${r.errors.slice(0, 3).join('; ')}`);
    }
    const ins = this.#db.prepare('INSERT OR IGNORE INTO events (v, at, actor, kind, wo, data, proof, source_key, family, value) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
    let added = 0;
    try {
      this.#db.exec('BEGIN IMMEDIATE');
      try {
        /** @type {Map<string, string|null>} */ const last = new Map();
        for (const ev of events) {
          const e = /** @type {any} */ (ev);
          if (e.family !== undefined) {
            const fam = String(e.family), val = String(e.value);
            if (!last.has(fam)) last.set(fam, this.lastValue(fam));
            if (last.get(fam) === val) continue;
            last.set(fam, val);
          }
          const r = ins.run(e.v || CONTRACT_V, e.at, e.actor, e.kind, e.wo, JSON.stringify(e.data), e.proof, e.key ?? null, e.family ?? null, e.family !== undefined ? String(e.value) : null);
          added += Number(r.changes);
        }
        this.#db.exec('COMMIT');
      } catch (e) { try { this.#db.exec('ROLLBACK'); } catch { } throw e; }
    } catch (e) { throw classify(e); }
    return { added, skipped: events.length - added, lastSeq: this.info().lastSeq };
  }

  /** @param {{ wo?: string, afterSeq?: number }} [q] @returns {Event[]} events in seq order */
  events(q = {}) {
    try {
      const where = [], args = [];
      if (q.wo) { where.push('wo = ?'); args.push(q.wo); }
      if (q.afterSeq) { where.push('seq > ?'); args.push(q.afterSeq); }
      const rows = this.#db.prepare(`SELECT v, seq, at, actor, kind, wo, data, proof FROM events${where.length ? ' WHERE ' + where.join(' AND ') : ''} ORDER BY seq`).all(...args);
      return rows.map((/** @type {any} */ r) => ({ v: r.v, seq: Number(r.seq), at: r.at, actor: r.actor, kind: r.kind, wo: r.wo ?? null, data: JSON.parse(r.data), proof: r.proof ?? null }));
    } catch (e) { throw classify(e); }
  }

  /** The nightly copy: VACUUM INTO a new file (Litestream does not support Windows). @param {string} to */
  backup(to) {
    if (fs.existsSync(to)) throw new StoreError('exists', `the backup file ${to} already exists; VACUUM INTO never overwrites`);
    fs.mkdirSync(path.dirname(path.resolve(to)), { recursive: true });
    try { this.#db.prepare('VACUUM INTO ?').run(to); } catch (e) { throw classify(e); }
    return to;
  }

  close() { try { this.#db.close(); } catch { } }
}
