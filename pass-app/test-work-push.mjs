// Owns the tests of the Work tab's Web Push (pass-app/work/push.mjs, lane L5, WO-UPG-L5-2). Each test is named after an acceptance line of
// the L5 brief (work breakdown "push": off by default; no content beyond "N cards wait"; a failure falls back to the in-app badge) or a rule
// of push.mjs. Called by tests/Test-Work.ps1 (CI's Core step) and by hand: node pass-app/test-work-push.mjs
// No network: the push service is a fake on 127.0.0.1; RFC 8291's own example (appendix A) checks the encryption. Throwaway state folders
// under TEMP only.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import http from 'node:http'; import crypto from 'node:crypto';
import { vapidKeys, checkSubscription, addSub, removeSub, readSubs, encrypt, vapidHeader, pushCards, shouldPush, cardsText, VAPID_FILE, SUBS_FILE, LAST_FILE, MAX_SUBS } from './work/push.mjs';

const results = [];
const check = (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });
const t0 = Date.now();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'work-push-test-'));
const b64u = (b) => Buffer.from(b).toString('base64url'); const unb64u = (s) => Buffer.from(s, 'base64url');
const stateDir = (name) => { const d = path.join(tmp, name); fs.mkdirSync(d, { recursive: true }); return d; };

/** A phone: its own key pair and auth secret, and a decrypt that follows RFC 8291 from the phone's side. */
function phone(endpoint) {
  const ecdh = crypto.createECDH('prime256v1'); ecdh.generateKeys(); const auth = crypto.randomBytes(16);
  const sub = { endpoint, keys: { p256dh: b64u(ecdh.getPublicKey()), auth: b64u(auth) } };
  const decrypt = (buf) => {
    const salt = buf.subarray(0, 16); const idlen = buf[20]; const asPub = buf.subarray(21, 21 + idlen); const ct = buf.subarray(21 + idlen);
    const ecdhOut = ecdh.computeSecret(asPub);
    const ikm = Buffer.from(crypto.hkdfSync('sha256', ecdhOut, auth, Buffer.concat([Buffer.from('WebPush: info\0'), ecdh.getPublicKey(), asPub]), 32));
    const cek = Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: aes128gcm\0'), 16));
    const nonce = Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: nonce\0'), 12));
    const d = crypto.createDecipheriv('aes-128-gcm', cek, nonce); d.setAuthTag(ct.subarray(ct.length - 16));
    const pt = Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
    if (pt[pt.length - 1] !== 2) throw new Error('no last-record delimiter');
    return pt.subarray(0, pt.length - 1).toString('utf8');
  };
  return { sub, decrypt };
}

// a fake push service on 127.0.0.1: answers each path with the status the test sets
const got = []; const statusFor = new Map();
const svc = http.createServer((req, res) => { const chunks = []; req.on('data', (d) => chunks.push(d)); req.on('end', () => { got.push({ path: req.url, headers: req.headers, body: Buffer.concat(chunks) }); res.writeHead(statusFor.get(req.url) ?? 201); res.end(); }); });
await new Promise((r) => svc.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${svc.address().port}`;
const T = { allowHttpLocal: true };

try {
  // ---- off by default ----
  const s1 = stateDir('off');
  const p1 = phone(`${base}/p1`); addSub(s1, p1.sub, T);
  const off = await pushCards({ state: s1, n: 3, workOn: true, ...T });
  check('push is off by default: with the alerts setting off (no push-on file) nothing is sent', off.sent === 0 && off.skipped?.includes('alerts are off') && got.length === 0, JSON.stringify(off));
  fs.writeFileSync(path.join(s1, 'push-on'), 'on');
  const offWork = await pushCards({ state: s1, n: 3, workOn: false, ...T });
  check('push is off while the Work tab is off (board.work), even with alerts on', offWork.sent === 0 && offWork.skipped?.includes('board.work') && got.length === 0, JSON.stringify(offWork));
  const s0 = stateDir('nosubs'); fs.writeFileSync(path.join(s0, 'push-on'), 'on');
  const none = await pushCards({ state: s0, n: 3, workOn: true, ...T });
  check('no phone subscribed: nothing is sent and no key file is made', none.sent === 0 && /no phone/.test(none.skipped) && !fs.existsSync(path.join(s0, VAPID_FILE)), JSON.stringify(none));

  // ---- no content beyond "N cards wait" ----
  const on = await pushCards({ state: s1, n: 3, workOn: true, ...T });
  const msg = got[0]; let payload = null; try { payload = JSON.parse(p1.decrypt(msg.body)); } catch (e) { payload = String(e.message); }
  check('with alerts on, the Work tab on and a phone subscribed, one push is sent', on.sent === 1 && on.failed === 0 && got.length === 1, JSON.stringify(on));
  check('no content beyond "N cards wait": the phone decrypts exactly { n, text: "3 cards wait" }', payload && typeof payload === 'object' && Object.keys(payload).sort().join() === 'n,text' && payload.n === 3 && payload.text === '3 cards wait', JSON.stringify(payload));
  check('one card reads "1 card waits"', cardsText(1) === '1 card waits' && cardsText(7) === '7 cards wait');
  check('the push is aes128gcm with a TTL, a collapse topic and VAPID auth', msg.headers['content-encoding'] === 'aes128gcm' && msg.headers.ttl === '86400' && msg.headers.topic === 'tide-cards' && /^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=[\w-]+$/.test(msg.headers.authorization || ''), JSON.stringify(msg.headers));

  // ---- VAPID (RFC 8292) ----
  const vk = vapidKeys(s1);
  const [, tok, k] = /^vapid t=([^,]+), k=(.+)$/.exec(msg.headers.authorization);
  const [h64, c64, sig64] = tok.split('.'); const claims = JSON.parse(unb64u(c64).toString());
  const pubJwk = { kty: 'EC', crv: 'P-256', x: b64u(unb64u(k).subarray(1, 33)), y: b64u(unb64u(k).subarray(33)) };
  const sigOk = crypto.verify('sha256', Buffer.from(`${h64}.${c64}`), { key: crypto.createPublicKey({ key: pubJwk, format: 'jwk' }), dsaEncoding: 'ieee-p1363' }, unb64u(sig64));
  check('the VAPID token is ES256-signed by the key it names, for the push service origin, expiring within 24 h', sigOk && k === vk.publicKey && claims.aud === base && claims.exp - Date.now() / 1000 <= 24 * 3600 && claims.exp > Date.now() / 1000 && /^(https:|mailto:)/.test(claims.sub), JSON.stringify(claims));
  check('the VAPID keys never change between restarts (kept in the state folder)', vapidKeys(s1).publicKey === vk.publicKey && vk.made === false);
  const s2 = stateDir('corrupt'); fs.writeFileSync(path.join(s2, VAPID_FILE), '{not json');
  let threw = ''; try { vapidKeys(s2); } catch (e) { threw = e.message; }
  check('a key file that cannot be read is an error, never a silent new key', /never replaced/.test(threw) && fs.readFileSync(path.join(s2, VAPID_FILE), 'utf8') === '{not json', threw);
  check('the keys live in the state folder, not the repo', fs.existsSync(path.join(s1, VAPID_FILE)) && !fs.existsSync(path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), VAPID_FILE)));

  // ---- RFC 8291 appendix A: the encryption matches the standard's own example byte for byte ----
  const asE = crypto.createECDH('prime256v1'); asE.setPrivateKey(unb64u('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw'));
  const rfc = encrypt(Buffer.from('When I grow up, I want to be a watermelon'), { p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', auth: 'BTBZMqHH6r4Tts7J_aSIgg' }, { salt: unb64u('DGv6ra1nlYgDCS1FRnbzlw'), ephemeral: asE });
  const want = 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN';
  check('the encryption matches RFC 8291 appendix A byte for byte', b64u(rfc) === want, b64u(rfc));

  // ---- a failure falls back to the in-app badge ----
  const s3 = stateDir('fail'); fs.writeFileSync(path.join(s3, 'push-on'), 'on');
  const p3 = phone(`${base}/down`); addSub(s3, p3.sub, T); statusFor.set('/down', 500);
  let fail; let threw3 = false; try { fail = await pushCards({ state: s3, n: 2, workOn: true, ...T }); } catch { threw3 = true; }
  const last = JSON.parse(fs.readFileSync(path.join(s3, LAST_FILE), 'utf8'));
  check('a failure falls back to the in-app badge: it never throws, says fallback badge and writes the last result', !threw3 && fail.sent === 0 && fail.failed === 1 && fail.fallback === 'badge' && last.fallback === 'badge' && last.failed === 1, JSON.stringify(fail));
  check('a failure keeps the phone subscribed (the push service may be down for a while)', readSubs(s3).length === 1);
  const s4 = stateDir('noanswer'); fs.writeFileSync(path.join(s4, 'push-on'), 'on'); addSub(s4, phone('http://127.0.0.1:9/never').sub, T);
  const dead = await pushCards({ state: s4, n: 1, workOn: true, timeoutMs: 1500, ...T });
  check('a push service that cannot be reached also falls back to the badge, with the reason', dead.failed === 1 && dead.fallback === 'badge' && dead.errors.length === 1, JSON.stringify(dead));
  statusFor.set('/gone', 410); const s5 = stateDir('gone'); fs.writeFileSync(path.join(s5, 'push-on'), 'on'); addSub(s5, phone(`${base}/gone`).sub, T); addSub(s5, phone(`${base}/fine`).sub, T);
  const gone = await pushCards({ state: s5, n: 4, workOn: true, ...T });
  check('a phone the push service says is gone (410) is forgotten; the others still get theirs', gone.gone === 1 && gone.sent === 1 && gone.fallback === null && readSubs(s5).map((s) => s.endpoint).join() === `${base}/fine`, JSON.stringify(gone));

  // ---- subscriptions ----
  const real = phone('https://fcm.googleapis.com/fcm/send/abc123').sub;
  check('a subscription to a known push service over https is kept', checkSubscription(real).ok === true);
  check('an http endpoint is refused', checkSubscription({ ...real, endpoint: 'http://fcm.googleapis.com/x' }).ok === false);
  check('an endpoint on any other host is refused (the PC never calls a host a subscription names)', checkSubscription({ ...real, endpoint: 'https://example.com/push' }).ok === false && checkSubscription({ ...real, endpoint: 'https://fcm.googleapis.com.example.com/x' }).ok === false);
  check('the local test endpoint is refused without the test option', checkSubscription(phone(`${base}/x`).sub).ok === false);
  check('bad keys are refused (p256dh not 65 bytes, auth not 16 bytes, not a curve point)', checkSubscription({ ...real, keys: { ...real.keys, auth: b64u(Buffer.alloc(8)) } }).ok === false
    && checkSubscription({ ...real, keys: { ...real.keys, p256dh: b64u(Buffer.alloc(33, 2)) } }).ok === false && checkSubscription({ ...real, keys: { ...real.keys, p256dh: b64u(Buffer.concat([Buffer.from([4]), Buffer.alloc(64, 7)])) } }).ok === false);
  const s6 = stateDir('subs');
  for (let i = 0; i < MAX_SUBS + 2; i++) addSub(s6, phone(`https://fcm.googleapis.com/fcm/send/p${i}`).sub);
  addSub(s6, phone('https://fcm.googleapis.com/fcm/send/p6').sub);
  const kept = readSubs(s6);
  check(`at most ${MAX_SUBS} phones are kept, newest last, and the same endpoint replaces itself`, kept.length === MAX_SUBS && kept[kept.length - 1].endpoint.endsWith('/p6') && new Set(kept.map((s) => s.endpoint)).size === MAX_SUBS, kept.map((s) => s.endpoint.slice(-2)).join());
  check('removing a phone forgets it', removeSub(s6, 'https://fcm.googleapis.com/fcm/send/p6').removed === 1 && readSubs(s6).length === MAX_SUBS - 1);
  check('the subscriptions file is in the state folder', fs.existsSync(path.join(s6, SUBS_FILE)));

  // ---- when to push ----
  check('push only when a new card arrived, at most once a minute', shouldPush(2, 3, 0, 120000) && !shouldPush(3, 3, 0, 120000) && !shouldPush(3, 2, 0, 120000) && !shouldPush(2, 3, 100000, 120000));
} catch (e) { check('the push tests ran to the end without a crash', false, e.stack || e.message); }
finally { svc.close(); try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { } }

const failed = results.filter((r) => !r.pass);
for (const r of results) console.log(`${r.pass ? 'PASS' : 'FAIL'}: ${r.name}`);
console.log(`Work tests: ${results.length - failed.length} passed, ${failed.length} failed (push, ${Math.round((Date.now() - t0) / 1000)} s)`);
process.exit(failed.length ? 1 : 0);
