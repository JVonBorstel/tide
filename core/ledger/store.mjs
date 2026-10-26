// @ts-check
// The record of truth: an append-only event log in SQLite (build-way 2.2 and 3.1, contract core/contracts/event.schema.json).
// This file is the only one that touches node:sqlite, so better-sqlite3 (the runner-up, build-way 10.1) can be swapped in here alone.
// node:sqlite is built into Node 22 (behind --experimental-sqlite on 22.12; cli.mjs adds the flag only when needed) and Node 24.
// Rules kept here, not by callers:
//   - events are only ever appended: SQLite triggers refuse every UPDATE and DELETE on the events table;
//   - every event is checked against the event contract before it is written; one bad event writes nothing (one transaction);
//   - an import names each event with a source key, so a rerun adds 0 events (INSERT OR IGNORE on a UNIQUE column);
//   - WAL journal, STRICT tables, a schema version (PRAGMA user_version), one writer (the Node core).
// Errors carry a code a program can act on: unavailable, corrupt, locked, newer-schema, bad-event, append-only.
import fs from 'node:fs';
import path from 'node:path';
import { validate } from '../contracts/validate.mjs';

export const SCHEMA_VERSION = 1;
/** The event contract version this code writes (common.schema.json version: 1.x). */
export const CONTRACT_V = '1.0';

export class StoreError extends Error {
  /** @param {string} code @param {string} message */
  constructor(code, message) { super(message); this.code = code; }
}

/** @returns {Promise<any>} the node:sqlite module, or a StoreError('unavailable') in plain words */
export async function sqliteModule() {
  try { return await import('node:sqlite'); } catch (e) {
    throw new StoreError('unavailable', `node:sqlite is not available in Node ${process.versions.node} (Node 22 needs --experimental-sqlite; run through core/ledger/cli.mjs, which adds it)`);
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
  source_key TEXT UNIQUE
) STRICT;
CREATE INDEX IF NOT EXISTS events_wo ON events (wo, seq);
CREATE INDEX IF NOT EXISTS events_kind ON events (kind, seq);
CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'events are append-only: an event is never changed'); END;
CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'events are append-only: an event is never deleted'); END;
`;

/** @param {unknown} e */
function classify(e) {
  const m = String(/** @type {any} */ (e)?.message || e);
  if (/not a database|malformed|file is encrypted|disk image/i.test(m)) return new StoreError('corrupt', `the event store file is damaged (${m.slice(0, 120)}); restore the nightly copy (VACUUM INTO) or build a new one from the sources`);
  if (/locked|busy/i.test(m)) return new StoreError('locked', `the event store is locked by another writer (${m.slice(0, 120)}); there is one writer, so try again when it is done`);
  if (/append-only/.test(m)) return new StoreError('append-only', m.replace(/^.*?(events are append-only)/, '$1'));
  return e instanceof StoreError ? e : new StoreError('error', m.slice(0, 300));
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
    const ver = Number(db.prepare('PRAGMA user_version').get()?.user_version ?? 0);
    if (ver > SCHEMA_VERSION) throw new StoreError('newer-schema', `the event store is schema ${ver}, newer than this code (${SCHEMA_VERSION}); update the code, never the file`);
    if (!opt.readOnly) {
      if (file !== ':memory:') db.exec('PRAGMA journal_mode = WAL');
      db.exec(DDL);
      if (ver < SCHEMA_VERSION) db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
    } else if (ver === 0) throw new StoreError('corrupt', 'the file has no event store schema (user_version 0)');
  } catch (e) { try { db?.close(); } catch { } throw classify(e); }
  return new Store(db, file);
}

/** @typedef {{ v?: string, seq?: number, at: string, actor: string, kind: string, wo: string | null, data: object, proof: string | null }} Event */

export class Store {
  /** @param {any} db @param {string} file */
  constructor(db, file) { this.db = db; this.file = file; }

  /** @returns {{ version: number, journal: string, events: number, lastSeq: number }} */
  info() {
    try {
      const version = Number(this.db.prepare('PRAGMA user_version').get().user_version);
      const journal = String(this.db.prepare('PRAGMA journal_mode').get().journal_mode);
      const r = this.db.prepare('SELECT COUNT(*) AS n, COALESCE(MAX(seq), 0) AS last FROM events').get();
      return { version, journal, events: Number(r.n), lastSeq: Number(r.last) };
    } catch (e) { throw classify(e); }
  }

  /**
   * Append events (all or none). Each may carry a `key` (its source key): an event whose key is already stored is skipped.
   * @param {Array<Event & { key?: string }>} events
   * @returns {{ added: number, skipped: number, lastSeq: number }}
   */
  append(events) {
    for (const [i, ev] of events.entries()) {
      const { key, seq, ...body } = /** @type {any} */ (ev);
      const r = validate('event', { v: CONTRACT_V, seq: 1, ...body });
      if (!r.ok) throw new StoreError('bad-event', `event ${i + 1} (${body.kind} ${body.wo ?? ''}) breaks the event contract: ${r.errors.slice(0, 3).join('; ')}`);
    }
    const ins = this.db.prepare('INSERT OR IGNORE INTO events (v, at, actor, kind, wo, data, proof, source_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
    let added = 0;
    try {
      this.db.exec('BEGIN IMMEDIATE');
      try {
        for (const ev of events) {
          const r = ins.run(ev.v || CONTRACT_V, ev.at, ev.actor, ev.kind, ev.wo, JSON.stringify(ev.data), ev.proof, /** @type {any} */ (ev).key ?? null);
          added += Number(r.changes);
        }
        this.db.exec('COMMIT');
      } catch (e) { try { this.db.exec('ROLLBACK'); } catch { } throw e; }
    } catch (e) { throw classify(e); }
    return { added, skipped: events.length - added, lastSeq: this.info().lastSeq };
  }

  /** @param {{ wo?: string, afterSeq?: number }} [q] @returns {Event[]} events in seq order */
  events(q = {}) {
    try {
      const where = [], args = [];
      if (q.wo) { where.push('wo = ?'); args.push(q.wo); }
      if (q.afterSeq) { where.push('seq > ?'); args.push(q.afterSeq); }
      const rows = this.db.prepare(`SELECT v, seq, at, actor, kind, wo, data, proof FROM events${where.length ? ' WHERE ' + where.join(' AND ') : ''} ORDER BY seq`).all(...args);
      return rows.map((r) => ({ v: r.v, seq: Number(r.seq), at: r.at, actor: r.actor, kind: r.kind, wo: r.wo ?? null, data: JSON.parse(r.data), proof: r.proof ?? null }));
    } catch (e) { throw classify(e); }
  }

  /** Run raw SQL (tests prove the triggers refuse updates and deletes). @param {string} sql */
  exec(sql) { try { this.db.exec(sql); } catch (e) { throw classify(e); } }

  /** The nightly copy: VACUUM INTO a new file (Litestream does not support Windows). @param {string} to */
  backup(to) {
    if (fs.existsSync(to)) throw new StoreError('exists', `the backup file ${to} already exists; VACUUM INTO never overwrites`);
    fs.mkdirSync(path.dirname(path.resolve(to)), { recursive: true });
    try { this.db.prepare('VACUUM INTO ?').run(to); } catch (e) { throw classify(e); }
    return to;
  }

  close() { try { this.db.close(); } catch { } }
}
