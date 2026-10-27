// Owns the front matter line format of BRIEF.md and REPORT.md: parse it into the brief and report contract objects, and write it back.
// Called by core/contracts/validate.mjs (.md files), and by lanes L1 (importers) and L3 (report parser, new-brief). Zero dependencies.

// The marks a dod line may use. The build-way template writes check marks; plain words are the same thing.
const MARKS = new Map([['yes', 'yes'], ['✓', 'yes'], ['no', 'no'], ['✗', 'no'], ['x', 'no'], ['n/a', 'n/a'], ['–', 'n/a'], ['-', 'n/a']]);
const TESTS_FORM = '"<suite> <passed>/<failed>; ..." or none';
const DOD_FORM = '"<item> yes|no|n/a | ..."';

function parseTests(v) {
  if (v === 'none' || v === '') return { value: [] };
  const out = [];
  for (const part of v.split(';').map((s) => s.trim()).filter(Boolean)) {
    const m = /^(\S+)\s+(\d+)\/(\d+)$/.exec(part);
    if (!m) return { error: `tests must be ${TESTS_FORM}; "${part}" is not` };
    out.push({ suite: m[1], passed: Number(m[2]), failed: Number(m[3]) });
  }
  return { value: out };
}

function parseDod(v) {
  const out = {};
  for (const part of v.split('|').map((s) => s.trim()).filter(Boolean)) {
    const m = /^(\S+)\s+(\S+)$/.exec(part);
    const mark = m && MARKS.get(m[2].toLowerCase());
    if (!mark) return { error: `dod must be ${DOD_FORM}; "${part}" is not` };
    out[m[1]] = mark;
  }
  return { value: out };
}

// Typed keys get their contract shape; every other value stays a string and the schema judges it.
function typed(key, v) {
  if (key === 'tests') return parseTests(v);
  if (key === 'dod') return parseDod(v);
  if (key === 'depth') { const m = /^(?:BRAIN_AGENT_DEPTH=)?(\d+)$/.exec(v); return { value: m ? Number(m[1]) : v }; }
  return { value: v };
}

// One "key: value" per line between two --- lines. " # note" at the end of a line is a comment ("plans/x.md#g4" is not: no space before #).
// Returns { ok: true, data, body } or { ok: false, error } with the line number in plain words.
export function parseFrontMatter(text) {
  const lines = String(text).replace(/^﻿/, '').split(/\r?\n/);
  if (lines[0].trim() !== '---') return { ok: false, error: 'no front matter: the first line must be ---' };
  const end = lines.findIndex((l, i) => i > 0 && l.trim() === '---');
  if (end < 0) return { ok: false, error: 'front matter is not closed: no second --- line' };
  const data = {};
  for (let i = 1; i < end; i++) {
    const raw = lines[i].replace(/\s+#\s.*$/, '').trim();
    if (!raw) continue;
    const m = /^([a-z][a-zA-Z0-9]*):(?:\s+(.*))?$/.exec(raw);
    if (!m) return { ok: false, error: `line ${i + 1} is not "key: value"` };
    if (m[1] in data) return { ok: false, error: `line ${i + 1}: "${m[1]}" appears twice` };
    const t = typed(m[1], (m[2] || '').trim());
    if (t.error) return { ok: false, error: `line ${i + 1}: ${t.error}` };
    data[m[1]] = t.value;
  }
  return { ok: true, data, body: lines.slice(end + 1).join('\n') };
}

function line(key, v) {
  if (key === 'tests') return v.length ? v.map((t) => `${t.suite} ${t.passed}/${t.failed}`).join('; ') : 'none';
  if (key === 'dod') return Object.entries(v).map(([k, m]) => `${k} ${m}`).join(' | ');
  return String(v);
}

// The inverse of parseFrontMatter for a brief or report object: keys in the object's order, one per line.
export function formatFrontMatter(data, body = '') {
  const rows = Object.entries(data).map(([k, v]) => `${k}: ${line(k, v)}`);
  return ['---', ...rows, '---', body].join('\n');
}
