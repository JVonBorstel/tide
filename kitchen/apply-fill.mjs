// Apply fill: opens a job posting's application form on Jordan's PC and fills it from his apply packet, then leaves the window to him.
//   node kitchen/apply-fill.mjs --item <id>                                   fill only (Chef's "Fill it on my PC")
//   node kitchen/apply-fill.mjs --item <id> --submit --packet-hash <sha256>   fill, then send once if every gate holds (Chef's one tap)
//   node kitchen/apply-fill.mjs --item <id> --print-hash                      the packet hash Chef shows Jordan for review
// Reads <career>\tracker.json (the item's link), <career>\packets\<id>\{answers.json,cover.txt}, <career>\profile.json and the one
// locked resume <career>\resume-locked.pdf. Writes only <career>\packets\<id>\fill-report.json (and submitted.json, see below).
// Browser: Google Chrome (CHROME_EXE), else Microsoft Edge (MSEDGE_EXE), always with a DEDICATED profile <kitchen>\apply-<browser>-profile:
// never Jordan's own profile or cookies. It talks the DevTools protocol over the browser's own 127.0.0.1 socket; the only other traffic is
// the page itself, opened at the posting's own apply URL. No dependencies (Node 22: global WebSocket).
// Privacy: values from the profile and packet go only into the page; logs and the report carry field labels, never values.
//
// GUARD: in fill mode this file never sends an application. Outside the one SEND-ONLY region at the bottom there is no pointer or key
// input, no form-sending call and no Enter key, and fields are filled with plain value setters plus input/change events. The region's
// single function is called from exactly one place, behind --submit and every gate (packet hash, no captcha, required fields, known
// site, not sent before). tests/Test-ApplyFill.ps1 checks this source statically. Captchas are never touched, only detected.
// Packet hash = sha256(bytes of answers.json, then bytes of resume-locked.pdf): what Jordan reviewed is exactly what gets sent.
// Exit: 0 page filled (fully or partly, applied or needs-you), 1 failure, 2 bad args / missing tracker item, packet, resume or profile,
// 3 already sent once (submitted.json exists; nothing is opened).
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const argv = process.argv.slice(2);
const opt = (k) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
const opts = { item: opt('--item'), submit: argv.includes('--submit'), hash: String(opt('--packet-hash') || '').toLowerCase(), printHash: argv.includes('--print-hash') };
const say = (m) => console.log(`apply-fill: ${m}`);
const die = (code, m) => { say(m); process.exit(code); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
setTimeout(() => die(1, 'timed out after 120 s (the browser window stays open)'), 120000);

if (!opts.item || !/^[A-Za-z0-9_-]{1,40}$/.test(opts.item)) die(2, 'usage: node kitchen/apply-fill.mjs --item <id> [--submit --packet-hash <sha256> | --print-hash]');
const career = path.resolve(process.env.PASS_CAREER_DIR || path.join(os.userInfo().homedir, 'gemini-brain', 'projects', 'career'));
const kitchen = path.resolve(process.env.BRAIN_KITCHEN || path.join(process.env.LOCALAPPDATA || '', 'brain-kitchen'));
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));
const has = (f) => { try { const s = fs.statSync(f); return s.isFile() && s.size > 0; } catch { return false; } };

let items = null;
try { const d = readJson(path.join(career, 'tracker.json')); items = Array.isArray(d) ? d : d?.items; } catch (e) { die(2, `tracker.json is missing or unreadable (${e.code || 'bad JSON'})`); }
const item = (Array.isArray(items) ? items : []).find((x) => x && x.id === opts.item);
if (!item) die(2, `no item ${opts.item} in tracker.json`);
const packetDir = path.join(career, 'packets', opts.item);
const answersFile = path.join(packetDir, 'answers.json'), coverFile = path.join(packetDir, 'cover.txt');
const PACKET_FILES = ['answers.json', 'cover.txt', 'link.txt', 'resume.pdf'];   // same order as apply-prep.ps1 and Chef's packetHash
const fullPacket = PACKET_FILES.every((x) => fs.existsSync(path.join(packetDir, x)));
const resumeFile = fullPacket ? path.join(packetDir, 'resume.pdf') : path.join(career, 'resume-locked.pdf');
const marker = path.join(packetDir, 'submitted.json');
if (!fs.existsSync(packetDir) || (!has(answersFile) && !has(coverFile))) die(2, `no apply packet for ${opts.item} (packets\\${opts.item} is missing or empty)`);
if (!has(resumeFile)) die(2, 'the locked resume is missing (resume-locked.pdf in the career folder)');
const packetHash = fullPacket ? PACKET_FILES.reduce((h, x) => h.update(fs.readFileSync(path.join(packetDir, x))), crypto.createHash('sha256')).digest('hex')
  : crypto.createHash('sha256').update(has(answersFile) ? fs.readFileSync(answersFile) : Buffer.alloc(0)).update(fs.readFileSync(resumeFile)).digest('hex');
if (opts.printHash) { console.log(packetHash); process.exit(0); }
// Once sent, never again: not a second send, and not a fresh fill over the record either (that would invite a manual resend).
if (fs.existsSync(marker)) die(3, `${opts.item} was already sent once (packets\\${opts.item}\\submitted.json exists); not opening it again`);
let answers = [];
if (has(answersFile)) { try { answers = readJson(answersFile); } catch { die(2, 'answers.json is not valid JSON'); } if (!Array.isArray(answers)) die(2, 'answers.json is not a list'); }
let profile = null; try { profile = readJson(path.join(career, 'profile.json')); } catch { }
if (!profile || typeof profile !== 'object' || !(profile.name || profile.email)) die(2, 'profile.json is missing or empty');
const cover = has(coverFile) ? fs.readFileSync(coverFile, 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').trim() : '';

let url = null; try { url = new URL(String(item.applyUrl || item.link || '')); } catch { }
if (!url || !/^https?:$/.test(url.protocol)) die(2, `${opts.item} has no http(s) link`);
// Site by host. A loopback host is never a real job board, so there the first path segment names the fixture (tests only).
function siteOf(u) {
  const h = u.hostname.toLowerCase();
  if (/^(127\.0\.0\.1|localhost|\[::1\])$/.test(h)) { const s = u.pathname.split('/')[1]; return ['greenhouse', 'lever', 'ashby'].includes(s) ? s : 'other'; }
  if (/(^|\.)greenhouse\.io$/.test(h)) return 'greenhouse';
  if (/(^|\.)lever\.co$/.test(h)) return 'lever';
  if (/(^|\.)ashbyhq\.com$/.test(h)) return 'ashby';
  return 'other';
}
// Posting page -> its form: Greenhouse keeps the form on the posting page; Lever adds /apply; Ashby adds /application.
function applyUrl(u, site) {
  const posting = /^\/[^/]+\/[0-9a-f-]{20,}\/?$/i.test(u.pathname);
  if (site === 'lever' && /^jobs\.(eu\.)?lever\.co$/i.test(u.hostname) && posting) u.pathname = u.pathname.replace(/\/?$/, '/apply');
  if (site === 'ashby' && /^jobs\.ashbyhq\.com$/i.test(u.hostname) && posting) u.pathname = u.pathname.replace(/\/?$/, '/application');
  return u.href;
}
const site = siteOf(url);
const target = site === 'other' ? url.href : applyUrl(url, site);

// ---- matching: page labels -> profile values and packet answers. Labels only ever leave this process as report text. ----
const norm = (s) => String(s ?? '').toLowerCase().replace(/\(required\)|[*✱]/g, ' ').replace(/[^a-z0-9]+/g, ' ').trim();
const toText = (v) => v == null ? '' : typeof v === 'boolean' ? (v ? 'Yes' : 'No') : Array.isArray(v) ? v.map(toText).filter(Boolean).join(', ') : String(v).replace(/\r\n/g, '\n').trim();
const P = profile, eeo = P.eeo && typeof P.eeo === 'object' ? P.eeo : {};
const parts = String(P.name || '').trim().split(/\s+/).filter(Boolean);
const first = P.firstName || parts[0] || '', last = P.lastName || parts.slice(1).join(' ');
// [pattern on the normalised label, value, flags]: s = short labels only (a long label is a question, not "Email"), c = choice fields only.
// Order matters: sponsorship questions often also say "authorized"; LinkedIn/GitHub before website.
const RULES = [
  [/\bsponsor/, P.needsSponsorship, ''],
  [/\bauthori[sz](ed|ation) to work\b|\bwork authori[sz]ation\b|\beligib\w* to work\b|\blegally (authori[sz]ed|eligible|permitted|able)\b|\bright to work\b/, P.workAuthorization, ''],
  [/\brelocat/, P.willingToRelocate, ''],
  [/\b(salary|compensation|pay) (expectation|requirement)s?\b|\b(expected|desired) (salary|compensation|pay)\b/, P.salaryExpectation, ''],
  [/\bstart date\b|\bearliest start\b|\bwhen can you start\b|\bavailable to start\b|\bnotice period\b/, P.earliestStart, ''],
  [/\bgender\b/, eeo.gender, 'c'], [/\bhispanic\b|\blatin[oax]\b/, eeo.hispanic, 'c'], [/\brace\b|\bethnicit/, eeo.race, 'c'],
  [/\bveteran\b/, eeo.veteran, 'c'], [/\bdisabilit/, eeo.disability, 'c'],
  [/\blinkedin\b/, P.linkedin, 's'], [/\bgithub\b/, P.github, 's'],
  [/\b(first|given) name\b|^first$/, first, 's'], [/\b(last|family) name\b|\bsurname\b|^last$/, last, 's'],
  [/^(full |legal |your )?name$|\bfull name\b|\blegal name\b/, P.name, 's'],
  [/\be ?mail\b/, P.email, 's'], [/\b(phone|mobile|telephone|cell)\b/, P.phone, 's'],
  [/\b(website|portfolio|personal site|blog)\b/, P.website, 's'],
  [/\blocation\b|\bwhere are you (based|located)\b|\baddress\b/, [P.city, P.state].filter(Boolean).join(', '), 's'],
  [/\bcountry\b/, P.country, 's'], [/\b(state|province)\b/, P.state, 's'], [/\bcity\b/, P.city, 's'],
];
function fromProfile(text, kind) {
  const t = norm(text), choice = kind === 'select' || kind === 'radio';
  for (const [re, val, fl] of RULES) {
    if (fl === 's' && t.length > 50) continue;
    if (fl === 'c' && !choice) continue;
    if (re.test(t)) return toText(val);
  }
  return undefined;
}
// The packet answer whose question best matches the label: exact, near-containment, or high word overlap. Below that: not sure.
function matchAnswer(label) {
  const nl = norm(label); if (nl.length < 3) return null;
  let best = null, bs = 0;
  for (const a of answers) {
    const nq = norm(a?.question); if (!nq) continue;
    let s = 0;
    if (nq === nl) s = 1;
    else {
      const [sh, lo] = nq.length < nl.length ? [nq, nl] : [nl, nq];
      if (sh.length >= 12 && lo.includes(sh) && sh.length / lo.length >= 0.6) s = 0.9;
      else { const A = new Set(nq.split(' ')), B = new Set(nl.split(' ')); const n = [...A].filter((x) => B.has(x)).length; const j = n / (A.size + B.size - n); if (j >= 0.75) s = j * 0.9; }
    }
    if (s > bs) { bs = s; best = a; }
  }
  return best;
}
// Option index for a value: exact, then a unique Yes/No by first word, then a unique prefix. Ambiguous means not sure.
function pickOption(options, v) {
  const nv = norm(v); if (!nv) return -1;
  const no = options.map(norm);
  let i = no.indexOf(nv); if (i >= 0) return i;
  const yn = /^(yes|true)$/.test(nv) ? 'yes' : /^(no|false)$/.test(nv) ? 'no' : '';
  const uniq = (pred) => { const k = no.map((o, j) => pred(o) ? j : -1).filter((j) => j >= 0); return k.length === 1 ? k[0] : -1; };
  if (yn) return uniq((o) => o.split(' ')[0] === yn);
  return nv.length >= 4 ? uniq((o) => o.length >= 4 && (o.startsWith(nv) || nv.startsWith(o))) : -1;
}
const isCover = (f) => /\bcover ?(letter|note)\b/.test(norm(`${f.label} ${f.ph} ${f.name}`));
function decide(f) {
  if (f.hasValue) return { why: 'already filled (kept as is)' };
  if (f.kind === 'checkbox') return { why: 'checkbox: Jordan ticks it' };
  if (f.kind === 'other') return { why: 'unusual field type: Jordan fills it' };
  if (f.combo) return { why: 'autocomplete dropdown: Jordan picks' };
  const text = f.label || f.ph || f.name;
  if (!norm(text)) return { why: 'no label: not sure what it is' };
  if (f.kind === 'textarea' && isCover(f)) return cover ? { v: cover } : { why: 'no cover note in packet' };
  const a = matchAnswer(f.label || f.ph);
  let v;
  if (a) { v = toText(a.answer); if (!v) return { why: a.needsJordan ? 'needs Jordan' : 'no answer in packet' }; }
  else { v = fromProfile(text, f.kind); if (v === undefined) return { why: 'not sure' }; if (!v) return { why: 'not in profile' }; }
  if (f.kind === 'select' || f.kind === 'radio') { const k = pickOption(f.options, v); return k >= 0 ? { opt: k } : { why: 'no matching option' }; }
  return { v };
}

// ---- page-side functions: run in an isolated world (page scripts can't see or wrap them), sharing only the DOM ----
function pageScan() {
  const T = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
  const CAP = '.g-recaptcha,.h-captcha,.cf-turnstile,[data-sitekey],iframe[src*="recaptcha"],iframe[src*="hcaptcha"],iframe[src*="turnstile"],iframe[src*="challenges.cloudflare.com"],iframe[title*="captcha" i],iframe[title*="challenge" i]';
  const shown = (el) => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const strip = (n) => { const c = n.cloneNode(true); c.querySelectorAll('input,select,textarea,option,button,script,style,svg').forEach((x) => x.remove()); return T(c.textContent); };
  // label-ish text just before the control's container: Lever custom questions and radio groups have no <label> of their own
  const near = (el) => {
    for (let p = el, k = 0; p && p !== document.body && k < 6; p = p.parentElement, k++)
      for (let s = p.previousElementSibling; s; s = s.previousElementSibling) { if (s.matches('input,select,textarea') || s.querySelector('input,select,textarea')) break; const t = strip(s); if (t) return t.slice(0, 300); }
    return '';
  };
  const labelOf = (el) => [...(el.labels || [])].map(strip).find(Boolean)
    || T((el.getAttribute('aria-labelledby') || '').split(/\s+/).map((id) => { const n = id && document.getElementById(id); return n ? strip(n) : ''; }).join(' '))
    || T(el.getAttribute('aria-label'));
  const kindOf = (el) => {
    if (el.tagName === 'TEXTAREA') return 'textarea';
    if (el.tagName === 'SELECT') return el.multiple ? 'other' : 'select';
    const ty = (el.getAttribute('type') || 'text').toLowerCase();
    if (['text', 'email', 'tel', 'url', 'number', 'search'].includes(ty)) return 'text';
    if (['file', 'radio', 'checkbox'].includes(ty)) return ty;
    return ['date', 'month', 'week', 'time', 'datetime-local', 'color', 'range'].includes(ty) ? 'other' : '';   // whitelist: buttons never listed
  };
  const els = [], fields = [], groups = new Map();
  for (const el of document.querySelectorAll('input,textarea,select')) {
    const kind = kindOf(el);
    if (!kind || el.disabled || (el.readOnly && kind !== 'file') || el.closest(CAP)) continue;
    if (kind !== 'file' && !shown(el)) continue;   // file inputs are often display:none behind a styled "Attach"
    if (kind === 'radio') {
      const key = el.name || `#${fields.length}`;
      let g = groups.get(key);
      if (!g) { g = { first: el, els: [], f: { i: els.length, kind, name: el.name, ph: '', label: '', options: [], required: false, hasValue: false } }; groups.set(key, g); els.push(g.els); fields.push(g.f); }
      g.els.push(el); g.f.options.push(labelOf(el) || el.value); g.f.required ||= el.required; g.f.hasValue ||= el.checked;
      continue;
    }
    const f = { i: els.length, kind, name: el.name || el.id || '', ph: T(el.placeholder), label: labelOf(el) || near(el), accept: el.accept || '',
      required: el.required || el.getAttribute('aria-required') === 'true',
      combo: el.tagName === 'INPUT' && (el.getAttribute('role') === 'combobox' || el.hasAttribute('aria-autocomplete') || el.getAttribute('aria-haspopup') === 'listbox') };
    f.hasValue = kind === 'file' ? el.files.length > 0 : kind === 'checkbox' ? el.checked : kind === 'select' ? el.selectedIndex > 0 && el.value !== '' : String(el.value).trim() !== '';
    if (kind === 'select') f.options = [...el.options].map((o) => T(o.text));
    els.push(el); fields.push(f);
  }
  for (const g of groups.values()) {
    const fsl = g.first.closest('fieldset')?.querySelector('legend'), rg = g.first.closest('[role=radiogroup]');
    g.f.label = (fsl && strip(fsl)) || (rg && labelOf(rg)) || near(g.first.closest('label') || g.first);
  }
  for (const f of fields) {
    f.required ||= /[*✱]\s*$/.test(f.label) || /\(required\)\s*$/i.test(f.label);
    f.label = f.label.replace(/\s*[*✱]\s*$/, '').replace(/\s*\(required\)\s*$/i, '').trim().slice(0, 200);
  }
  globalThis.__afEls = els;
  return { fields, captcha: !!document.querySelector(CAP), url: location.href };
}
// Plain value setters from the element's prototype (what React's own tracker can't intercept) plus input/change events so
// React-style forms register the value. No focus, no keys, no pointer.
function pageFill(list) {
  const els = globalThis.__afEls, done = [];
  const setProp = (el, prop, v) => { const d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), prop); if (d && d.set) d.set.call(el, v); else el[prop] = v; };
  const fire = (el) => { el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); el.dispatchEvent(new FocusEvent('focusout', { bubbles: true })); el.dispatchEvent(new FocusEvent('blur')); };
  for (const a of list) {
    try {
      const el = els[a.i];
      if (a.kind === 'radio') { setProp(el[a.opt], 'checked', true); fire(el[a.opt]); }
      else if (a.kind === 'select') { setProp(el, 'value', el.options[a.opt].value); fire(el); }
      else { setProp(el, 'value', a.v); fire(el); }
      done.push(a.i);
    } catch { }
  }
  return done;
}
function pageVerify(list) {
  const els = globalThis.__afEls;
  return list.filter((a) => { const el = els[a.i]; return a.kind === 'radio' ? el[a.opt].checked : a.kind === 'select' ? el.selectedIndex === a.opt : String(el.value).replace(/\r\n/g, '\n') === a.v; }).map((a) => a.i);
}

// ---- DevTools protocol over the browser's 127.0.0.1 WebSocket ----
class Cdp {
  constructor(ws) {
    this.ws = ws; this.n = 0; this.wait = new Map(); this.subs = new Set();
    ws.onmessage = (e) => {
      let m; try { m = JSON.parse(typeof e.data === 'string' ? e.data : Buffer.from(e.data).toString()); } catch { return; }
      if (m.id && this.wait.has(m.id)) { const w = this.wait.get(m.id); this.wait.delete(m.id); if (m.error) w.rej(new Error(`${w.method}: ${m.error.message}`)); else w.res(m.result || {}); }
      else if (m.method) for (const s of this.subs) s(m);
    };
    ws.onclose = () => { for (const w of this.wait.values()) w.rej(new Error('browser connection closed')); this.wait.clear(); };
  }
  send(method, params = {}, sessionId) {
    const id = ++this.n;
    return new Promise((res, rej) => { this.wait.set(id, { res, rej, method }); this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })); });
  }
  once(pred, ms) {
    return new Promise((res, rej) => {
      const t = setTimeout(() => { this.subs.delete(f); rej(new Error('event timeout')); }, ms);
      const f = (m) => { if (pred(m)) { clearTimeout(t); this.subs.delete(f); res(m); } };
      this.subs.add(f);
    });
  }
}
const connect = (u, ms) => new Promise((res, rej) => {
  const ws = new WebSocket(u);
  const t = setTimeout(() => { try { ws.close(); } catch { } rej(new Error('connect timeout')); }, ms);
  ws.onopen = () => { clearTimeout(t); res(new Cdp(ws)); };
  ws.onerror = () => { clearTimeout(t); rej(new Error('connect failed')); };
});
function findBrowser() {
  const pf = process.env.ProgramFiles || 'C:\\Program Files', pf86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', la = process.env.LOCALAPPDATA || '';
  const lists = [
    ['chrome', [process.env.CHROME_EXE, path.join(pf, 'Google\\Chrome\\Application\\chrome.exe'), path.join(pf86, 'Google\\Chrome\\Application\\chrome.exe'), la && path.join(la, 'Google\\Chrome\\Application\\chrome.exe')]],
    ['edge', [process.env.MSEDGE_EXE, path.join(pf86, 'Microsoft\\Edge\\Application\\msedge.exe'), path.join(pf, 'Microsoft\\Edge\\Application\\msedge.exe')]],
  ];
  for (const [name, list] of lists) for (const f of list) if (f && has(f)) return { name, exe: f };
  return null;
}
// Port 0 lets the browser pick a free port and write it to DevToolsActivePort in the profile; it binds 127.0.0.1 only. If an earlier
// run's window is still open, its socket answers and a new tab is opened there (a second launch on the same profile would just hand off).
async function openBrowser(b) {
  const prof = path.join(kitchen, `apply-${b.name}-profile`);
  fs.mkdirSync(prof, { recursive: true });
  const portFile = path.join(prof, 'DevToolsActivePort');
  const tryConnect = async () => {
    try { const [port, p] = fs.readFileSync(portFile, 'utf8').split(/\r?\n/); if (!/^\d+$/.test(port) || !/^\/devtools\/browser\/[\w-]+$/.test(p)) return null; return await connect(`ws://127.0.0.1:${port}${p}`, 3000); } catch { return null; }
  };
  let c = await tryConnect(); if (c) return { c, reused: true };
  fs.rmSync(portFile, { force: true });
  const args = [`--user-data-dir=${prof}`, '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1', '--no-first-run', '--no-default-browser-check'];
  if (process.env.APPLY_FILL_HEADLESS === '1') args.push('--headless=new', '--disable-gpu', '--disable-background-networking', '--disable-sync', '--disable-component-update', '--disable-extensions');   // tests only
  args.push('about:blank');
  const p = spawn(b.exe, args, { detached: true, stdio: 'ignore' }); p.on('error', () => { }); p.unref();   // outlives this script: the window is Jordan's
  for (const until = Date.now() + 20000; Date.now() < until; await sleep(250)) if (fs.existsSync(portFile) && (c = await tryConnect())) return { c, reused: false };
  throw new Error(`${b.name} did not open its debugging port`);
}

// ---- main ----
const filled = [], left = [];
const leave = (f, why) => left.push({ label: f.label || f.name || f.kind, why, required: !!f.required });
const writeReport = (r) => {
  try { fs.writeFileSync(path.join(packetDir, 'fill-report.json'), JSON.stringify({ at: new Date().toISOString(), url: target, site, ...r }, null, 2)); } catch { }
  // the short verdict Chef reads (pass-app/server.mjs): applied | filled | needs-you | failed, with the confirmation or the reason
  try { fs.writeFileSync(path.join(packetDir, 'fill-result.json'), JSON.stringify({ result: r.result, ...(r.confirmation && { confirmation: String(r.confirmation).slice(0, 300) }), ...(r.why && { reason: String(r.why).slice(0, 300) }) })); } catch { }
};
let cdp = null;
try {
  const b = findBrowser();
  if (!b) throw new Error('neither Chrome nor Edge was found');
  const o = await openBrowser(b); cdp = o.c;
  let targetId = null;
  if (!o.reused) targetId = (await cdp.send('Target.getTargets')).targetInfos.find((t) => t.type === 'page')?.targetId;
  if (!targetId) targetId = (await cdp.send('Target.createTarget', { url: 'about:blank' })).targetId;
  const { sessionId: sid } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const S = (m, p) => cdp.send(m, p, sid);
  await S('Page.enable');
  const loaded = cdp.once((m) => m.sessionId === sid && m.method === 'Page.loadEventFired', 45000);
  const nav = await S('Page.navigate', { url: target });
  if (nav.errorText) throw new Error(`the page did not open (${nav.errorText})`);
  await loaded.catch(() => { });   // a slow page: carry on and look for the form anyway
  cdp.send('Target.activateTarget', { targetId }).catch(() => { });
  let ctx = 0;
  const run = async (fn, arg, fresh) => {
    if (fresh || !ctx) { const { frameTree } = await S('Page.getFrameTree'); ctx = (await S('Page.createIsolatedWorld', { frameId: frameTree.frame.id, worldName: 'apply-fill' })).executionContextId; }
    const r = await S('Runtime.evaluate', { expression: `(${fn})(${JSON.stringify(arg ?? null)})`, contextId: ctx, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(`page script failed: ${String(r.exceptionDetails.exception?.description || r.exceptionDetails.text).split('\n')[0].slice(0, 160)}`);
    return r.result.value;
  };

  if (site === 'other') {
    const why = 'unsupported site, packet only';
    const result = opts.submit ? 'needs-you' : 'filled';
    writeReport({ browser: b.name, mode: opts.submit ? 'send' : 'fill', result, filled, left, captcha: false, why });
    cdp.ws.close();
    die(0, `${opts.item} other (${b.name}): ${why}; the page is open for Jordan`);
  }

  let scan = null;
  for (const until = Date.now() + 25000; Date.now() < until; await sleep(500)) {   // single-page forms (Ashby) draw after load
    try { scan = await run(pageScan, null, true); } catch { scan = null; }
    if (scan && scan.fields.filter((f) => f.kind !== 'file').length >= 2) break;
  }
  if (!scan || !scan.fields.length) throw new Error('no application form found on the page');

  // Files first: some boards parse the resume and pre-fill fields, which must not overwrite what is filled next.
  const files = scan.fields.filter((f) => f.kind === 'file');
  const coverBox = scan.fields.some((f) => f.kind === 'textarea' && isCover(f));
  const resumeField = files.find((f) => !isCover(f) && /\b(resume|cv)\b/.test(norm(`${f.label} ${f.name}`))) || files.find((f) => !isCover(f));
  let attached = 0;
  for (const f of files) {
    let file = null;
    if (isCover(f)) {
      if (coverBox) { leave(f, 'cover note pasted in the text box instead'); continue; }
      if (!cover) { leave(f, 'no cover note in packet'); continue; }
      if (f.accept && !/\.txt|text\/plain|text\/\*/i.test(f.accept)) { leave(f, 'cover file must be another format'); continue; }
      file = coverFile;
    } else if (f === resumeField) file = resumeFile;
    else { leave(f, 'file: Jordan attaches it'); continue; }
    if (f.hasValue) { leave(f, 'already has a file (kept)'); continue; }
    const { result } = await S('Runtime.evaluate', { expression: `globalThis.__afEls[${f.i}]`, contextId: ctx });
    await S('DOM.setFileInputFiles', { files: [file], objectId: result.objectId });
    filled.push(f.label || f.name || 'file'); attached++;
  }
  if (attached) await sleep(1500);

  scan = await run(pageScan, null, true);
  const plan = [];
  for (const f of scan.fields) {
    if (f.kind === 'file') continue;
    const d = decide(f);
    if (d.why) leave(f, d.why); else plan.push({ i: f.i, kind: f.kind, v: d.v, opt: d.opt, label: f.label || f.name, required: f.required });
  }
  const strip = (a) => ({ i: a.i, kind: a.kind, v: a.v, opt: a.opt });
  const done = new Set(await run(pageFill, plan.map(strip)));
  await sleep(400);
  const kept = new Set(await run(pageVerify, plan.map(strip)));
  for (const a of plan) if (done.has(a.i) && kept.has(a.i)) filled.push(a.label); else leave(a, 'the page did not keep the value');
  await sleep(600);

  let result = 'filled', why = '', confirmation = '';
  if (opts.submit) {
    const fin = await run(pageScan, null, true);
    const missing = fin.fields.filter((f) => f.required && !f.hasValue).map((f) => f.label || f.name || f.kind);
    why = opts.hash !== packetHash ? 'packet changed since Jordan reviewed it (hash mismatch)'
      : fin.captcha ? 'captcha: Jordan solves it'
      : missing.length ? `required field empty: ${missing.slice(0, 5).join('; ')}` : '';
    if (why) result = 'needs-you';
    else ({ result, why = '', confirmation = '' } = await submitApplicationOnce({ S, run, site, url: target }));
    if (result === 'applied') cdp.send('Target.closeTarget', { targetId }).catch(() => { });
  }
  const captcha = !!scan.captcha;
  writeReport({ browser: b.name, mode: opts.submit ? 'send' : 'fill', result, filled, left, captcha, ...(why && { why }), ...(confirmation && { confirmation }) });
  const nj = left.filter((l) => l.why === 'needs Jordan').length;
  const tail = result === 'applied' ? `applied: "${confirmation.slice(0, 100)}"` : result === 'needs-you' ? `needs you: ${why}; the window stays open` : 'the window is open for Jordan to review and send';
  await sleep(300); cdp.ws.close();
  die(0, `${opts.item} ${site} (${b.name}): filled ${filled.length}, left ${left.length} (${nj} need Jordan)${captcha ? ', captcha: Jordan solves it' : ''}; ${tail}`);
} catch (e) {
  writeReport({ result: 'failed', why: String(e.message).slice(0, 200), filled, left });
  try { cdp?.ws.close(); } catch { }
  die(1, `${opts.item}: failed: ${String(e.message).slice(0, 200)} (any open window stays for Jordan)`);
}

// >>> SEND-ONLY REGION: the only code in this file that presses anything. Reached only from the --submit path above, after the packet
// hash, captcha and required-field gates. It writes the submitted.json marker BEFORE pressing (exclusive create, so a crash or a second
// run can never send twice), presses the site's own send button exactly once, and never retries.
function pageFindSendButton(site) {
  const sel = { greenhouse: '#submit_app, button[type=submit], input[type=submit]', lever: '#btn-submit, button[type=submit]', ashby: 'button.ashby-application-form-submit-button, button[type=submit]' }[site];
  const b = sel && [...document.querySelectorAll(sel)].find((e) => e.getClientRects().length && !e.disabled);
  if (!b) return null;
  b.scrollIntoView({ block: 'center' });
  const r = b.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2, url: location.href, pre: (document.body?.innerText || '').replace(/\s+/g, ' ') };
}
function pageConfirm() {
  const t = (document.body?.innerText || '').replace(/\s+/g, ' ');
  const m = t.match(/[^.!?]{0,80}(thank(s| you)[^.!?]{0,60}(appl|interest|submi)|application (has been |was )?(received|submitted|sent)|we('ve| have) received your application|successfully (submitted|applied))[^.!?]{0,80}[.!?]?/i);
  const errs = [...document.querySelectorAll('.error, .field-error, .error-message, [role="alert"]')].filter((e) => e.getClientRects().length).map((e) => e.innerText.trim()).filter(Boolean);
  if (!errs.length && document.querySelector('[aria-invalid="true"]')) errs.push('a field is marked invalid');
  return { hit: m ? m[0].trim().slice(0, 200) : '', err: (errs[0] || '').replace(/\s+/g, ' ').slice(0, 120), url: location.href };
}
async function submitApplicationOnce({ S, run, site, url }) {
  const b = await run(pageFindSendButton, site, true);
  if (!b) return { result: 'needs-you', why: "the site's send button was not found" };
  let fd; try { fd = fs.openSync(marker, 'wx'); } catch { return { result: 'needs-you', why: 'already sent once (submitted.json exists)' }; }
  fs.writeSync(fd, JSON.stringify({ at: new Date().toISOString(), site, url, packetHash })); fs.closeSync(fd);
  await S('Page.bringToFront').catch(() => { });
  for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased'])
    await S('Input.dispatchMouseEvent', { type, x: b.x, y: b.y, button: type === 'mouseMoved' ? 'none' : 'left', clickCount: type === 'mouseMoved' ? 0 : 1 });
  const t0 = Date.now(); let err = '';
  while (Date.now() - t0 < 30000) {
    await sleep(700);
    let c; try { c = await run(pageConfirm, null, true); } catch { continue; }   // mid-navigation
    if (c.hit && (c.url !== b.url || !b.pre.includes(c.hit))) return { result: 'applied', confirmation: c.hit };
    err = c.err;
    if (err && Date.now() - t0 > 6000) break;
  }
  return { result: 'needs-you', why: err ? `validation error shown: ${err}` : 'no confirmation seen in 30 s (check the window; it will not be sent again)' };
}
// <<< SEND-ONLY REGION
