// @ts-check
// Owns Web Push for the Work tab (lane L5, WO-UPG-L5-2; build-way 10.1 "SSE + native Web Push (VAPID)"): the VAPID keys, the phone
// subscriptions, the message encryption (RFC 8291, aes128gcm), the VAPID header (RFC 8292) and one send per phone. Built on node:crypto
// only (no web-push package; build-way 10.2 item 3).
// Called by the Work API (pass-app/work/api.mjs, wired in a later slice) and pass-app/test-work-push.mjs.
// Rules kept here:
//   - off by default: nothing is sent unless the Board's alerts setting is on (<state>\push-on, the same switch as the ntfy alerts) AND
//     the caller says the Work tab is on AND a phone has subscribed;
//   - a message says only how many cards wait ("3 cards wait"); never a title, a goal, a repo or a WO id;
//   - a failure never throws to the caller: it is counted, written to <state>\work-push-last.json, and the in-app badge (the queue
//     count on the Board) stays the way Jordan learns of a card. A phone the push service says is gone (404/410) is forgotten;
//   - only the known push services are ever called (https, fixed host list, redirects never followed), so neither a stored subscription
//     nor a push service's answer can point the PC at another host;
//   - the VAPID keys are made once and kept in the state folder (never in the repo), so subscriptions keep working across restarts. A key
//     file that cannot be read is an error, never a silent new key (that would cut every phone off).
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export const VAPID_FILE = 'work-push-vapid.json';
export const SUBS_FILE = 'work-push-subs.json';
export const LAST_FILE = 'work-push-last.json';
export const MAX_SUBS = 5;
/** The push services browsers use (Chrome/Android, Firefox, Safari/iOS, Edge/Windows). */
export const PUSH_HOSTS = [/^fcm\.googleapis\.com$/, /^(?:[a-z0-9-]+\.)*push\.services\.mozilla\.com$/, /^web\.push\.apple\.com$/, /^(?:[a-z0-9-]+\.)*notify\.windows\.com$/];

const b64u = (/** @type {Buffer} */ b) => Buffer.from(b).toString('base64url');
const unb64u = (/** @type {string} */ s) => Buffer.from(String(s), 'base64url');

/** @param {string} file @param {unknown} obj */
function writePrivate(file, obj) {
  const t = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(t, JSON.stringify(obj, null, 1), { mode: 0o600 }); fs.renameSync(t, file);
}

/**
 * The VAPID key pair: made once, kept in <state>\work-push-vapid.json.
 * @param {string} state
 * @returns {{ publicKey: string, privateKey: crypto.KeyObject, made: boolean }} publicKey: the uncompressed P-256 point, base64url (what
 *   PushManager.subscribe takes as applicationServerKey)
 */
export function vapidKeys(state) {
  const file = path.join(state, VAPID_FILE);
  if (fs.existsSync(file)) {
    let d; try { d = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { throw new Error(`the Web Push key file ${VAPID_FILE} cannot be read (${/** @type {Error} */ (e).message}); it is never replaced by itself, because a new key cuts every phone off`); }
    const signKey = crypto.createPrivateKey({ key: d.privateJwk, format: 'jwk' });
    const pub = crypto.createPublicKey(signKey).export({ format: 'jwk' });
    const point = Buffer.concat([Buffer.from([4]), unb64u(String(pub.x)), unb64u(String(pub.y))]);
    if (b64u(point) !== d.publicKey) throw new Error(`the Web Push key file ${VAPID_FILE} does not hold a matching key pair`);
    return { publicKey: d.publicKey, privateKey: signKey, made: false };
  }
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const jwk = publicKey.export({ format: 'jwk' });
  const point = b64u(Buffer.concat([Buffer.from([4]), unb64u(String(jwk.x)), unb64u(String(jwk.y))]));
  fs.mkdirSync(state, { recursive: true });
  writePrivate(file, { v: 1, made: new Date().toISOString(), publicKey: point, privateJwk: privateKey.export({ format: 'jwk' }) });
  return { publicKey: point, privateKey, made: true };
}

/**
 * Check a subscription from PushSubscription.toJSON(): a known push service over https, a P-256 key and a 16-byte auth secret.
 * @param {any} sub @param {{ allowHosts?: RegExp[], allowHttpLocal?: boolean }} [o] the test options (never read from the environment)
 * @returns {{ ok: true, sub: { endpoint: string, keys: { p256dh: string, auth: string } } } | { ok: false, error: string }}
 */
export function checkSubscription(sub, o = {}) {
  if (!sub || typeof sub !== 'object') return { ok: false, error: 'a subscription is an object' };
  let u; try { u = new URL(String(sub.endpoint)); } catch { return { ok: false, error: 'the endpoint is not a URL' }; }
  const local = o.allowHttpLocal === true && u.protocol === 'http:' && u.hostname === '127.0.0.1';
  if (!local && u.protocol !== 'https:') return { ok: false, error: 'the endpoint must be https' };
  if (!local && ![...PUSH_HOSTS, ...(o.allowHosts || [])].some((re) => re.test(u.hostname))) return { ok: false, error: `${u.hostname} is not a known push service` };
  if (String(sub.endpoint).length > 1000) return { ok: false, error: 'the endpoint is too long' };
  const p = unb64u(sub.keys?.p256dh || ''), a = unb64u(sub.keys?.auth || '');
  if (p.length !== 65 || p[0] !== 4) return { ok: false, error: 'keys.p256dh must be an uncompressed P-256 key (65 bytes)' };
  if (a.length !== 16) return { ok: false, error: 'keys.auth must be 16 bytes' };
  try { crypto.createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: b64u(p.subarray(1, 33)), y: b64u(p.subarray(33)) }, format: 'jwk' }); } catch { return { ok: false, error: 'keys.p256dh is not a point on P-256' }; }
  return { ok: true, sub: { endpoint: String(sub.endpoint), keys: { p256dh: b64u(p), auth: b64u(a) } } };
}

/** @param {string} state @returns {Array<{ endpoint: string, keys: { p256dh: string, auth: string }, at: string }>} */
export function readSubs(state) {
  try { const d = JSON.parse(fs.readFileSync(path.join(state, SUBS_FILE), 'utf8')); return Array.isArray(d?.subs) ? d.subs : []; } catch { return []; }
}
/** @param {string} state @param {any[]} subs */
function writeSubs(state, subs) { writePrivate(path.join(state, SUBS_FILE), { v: 1, subs }); }

/**
 * Keep a phone's subscription (the newest MAX_SUBS phones; the same endpoint again replaces itself).
 * @param {string} state @param {any} sub @param {{ allowHosts?: RegExp[], allowHttpLocal?: boolean, now?: Date }} [o]
 */
export function addSub(state, sub, o = {}) {
  const c = checkSubscription(sub, o); if (!c.ok) return c;
  const subs = readSubs(state).filter((s) => s.endpoint !== c.sub.endpoint);
  subs.push({ ...c.sub, at: (o.now || new Date()).toISOString() });
  writeSubs(state, subs.slice(-MAX_SUBS));
  return { ok: true, count: Math.min(subs.length, MAX_SUBS) };
}
/** @param {string} state @param {string} endpoint */
export function removeSub(state, endpoint) {
  const subs = readSubs(state); const left = subs.filter((s) => s.endpoint !== String(endpoint));
  if (left.length !== subs.length) writeSubs(state, left);
  return { ok: true, removed: subs.length - left.length };
}

/**
 * Encrypt one message for one phone (RFC 8291, content coding aes128gcm, one record).
 * @param {Buffer} plaintext @param {{ p256dh: string, auth: string }} keys @param {{ salt?: Buffer, ephemeral?: crypto.ECDH }} [o] fixed values for tests only
 */
export function encrypt(plaintext, keys, o = {}) {
  const ua = unb64u(keys.p256dh), auth = unb64u(keys.auth);
  const as = o.ephemeral || crypto.createECDH('prime256v1'); if (!o.ephemeral) as.generateKeys();
  const asPub = as.getPublicKey();
  const ecdhOut = as.computeSecret(ua);
  const ikm = Buffer.from(crypto.hkdfSync('sha256', ecdhOut, auth, Buffer.concat([Buffer.from('WebPush: info\0'), ua, asPub]), 32));
  const salt = o.salt || crypto.randomBytes(16);
  const cek = Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: aes128gcm\0'), 16));
  const nonce = Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: nonce\0'), 12));
  const cipher = crypto.createCipheriv('aes-128-gcm', cek, nonce);
  const body = Buffer.concat([cipher.update(Buffer.concat([plaintext, Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const rs = Buffer.alloc(4); rs.writeUInt32BE(4096);
  return Buffer.concat([salt, rs, Buffer.from([asPub.length]), asPub, body]);
}

/**
 * The VAPID Authorization header (RFC 8292): a 12-hour ES256 token for the push service's origin.
 * @param {string} endpoint @param {{ publicKey: string, privateKey: crypto.KeyObject }} vapid @param {string} subject @param {Date} [now]
 */
export function vapidHeader(endpoint, vapid, subject, now = new Date()) {
  const head = b64u(Buffer.from(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = b64u(Buffer.from(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(now.getTime() / 1000) + 12 * 3600, sub: subject })));
  const sig = crypto.sign('sha256', Buffer.from(`${head}.${claims}`), { key: vapid.privateKey, dsaEncoding: 'ieee-p1363' });
  return `vapid t=${head}.${claims}.${b64u(sig)}, k=${vapid.publicKey}`;
}

/** The only words a message carries. @param {number} n */
export const cardsText = (n) => (n === 1 ? '1 card waits' : `${n} cards wait`);

/**
 * Tell every subscribed phone how many cards wait. Never throws; the answer says what happened.
 * @param {{ state: string, n: number, workOn: boolean, subject?: string, now?: Date, fetchImpl?: typeof fetch, allowHosts?: RegExp[], allowHttpLocal?: boolean, timeoutMs?: number }} o
 * @returns {Promise<{ sent: number, failed: number, gone: number, skipped: string | null, fallback: 'badge' | null, errors: string[] }>}
 */
export async function pushCards(o) {
  const res = { sent: 0, failed: 0, gone: 0, skipped: /** @type {string|null} */ (null), fallback: /** @type {'badge'|null} */ (null), errors: /** @type {string[]} */ ([]) };
  if (!fs.existsSync(path.join(o.state, 'push-on'))) { res.skipped = 'alerts are off (the Board setting)'; return res; }
  if (!o.workOn) { res.skipped = 'the Work tab is off (board.work)'; return res; }
  const subs = readSubs(o.state);
  if (!subs.length) { res.skipped = 'no phone has subscribed'; return res; }
  if (!(Number.isInteger(o.n) && o.n > 0)) { res.skipped = 'no cards wait'; return res; }
  let vapid; try { vapid = vapidKeys(o.state); } catch (e) { res.failed = subs.length; res.errors.push(/** @type {Error} */ (e).message); return finish(o, res); }
  const body = Buffer.from(JSON.stringify({ n: o.n, text: cardsText(o.n) }));
  const subject = o.subject || process.env.PASS_PUSH_SUBJECT || 'https://github.com/JVonBorstel/tide';
  const gone = new Set();
  await Promise.all(subs.map(async (s) => {
    const ok = checkSubscription(s, o); if (!ok.ok) { gone.add(s.endpoint); res.gone++; return; }
    try {
      const r = await (o.fetchImpl || fetch)(s.endpoint, { method: 'POST', redirect: 'manual', body: encrypt(body, s.keys), signal: AbortSignal.timeout(o.timeoutMs ?? 10000),
        headers: { Authorization: vapidHeader(s.endpoint, vapid, subject, o.now), 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '86400', Urgency: 'normal', Topic: 'tide-cards' } });
      if (r.status === 404 || r.status === 410) { gone.add(s.endpoint); res.gone++; }
      else if (r.status >= 200 && r.status < 300) res.sent++;
      else { res.failed++; res.errors.push(`${new URL(s.endpoint).hostname} answered ${r.status}`); }
    } catch (e) { res.failed++; res.errors.push(`${new URL(s.endpoint).hostname}: ${/** @type {any} */ (e)?.name === 'TimeoutError' ? 'no answer in time' : String(/** @type {Error} */ (e).message).slice(0, 120)}`); }
  }));
  if (gone.size) writeSubs(o.state, readSubs(o.state).filter((s) => !gone.has(s.endpoint)));
  return finish(o, res);
}
/** @param {{ state: string, now?: Date }} o @param {any} res */
function finish(o, res) {
  if (!res.sent && (res.failed || res.gone)) res.fallback = 'badge';
  try { writePrivate(path.join(o.state, LAST_FILE), { at: (o.now || new Date()).toISOString(), sent: res.sent, failed: res.failed, gone: res.gone, fallback: res.fallback, errors: res.errors.slice(0, 5) }); } catch { }
  return res;
}

/**
 * Push only when a new card arrived (the count went up), at most once a minute; a count that only went down never wakes the phone.
 * @param {number} before @param {number} now @param {number} lastAtMs @param {number} [nowMs]
 */
export const shouldPush = (before, now, lastAtMs, nowMs = Date.now()) => now > before && nowMs - lastAtMs >= 60000;
