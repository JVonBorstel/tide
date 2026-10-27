// The Board's notice memory (D-12): which notices this phone cleared, and which red bars it made thin, keyed so a changed notice shows again.
// Imported by app.js (renderNotices); pure, no DOM and no storage (app.js keeps the keys in localStorage), tested in node by pass-app/test-status-line.mjs.

// A notice's id: what it is (a chip or a red bar, and its chip words), the same while its words change.
export const noticeId = (n) => `${n.tone === 'broken' ? 'bar' : 'chip'}:${n.chip}`;
// Its words without the parts that tick on their own ("quiet for 4 min", "(3.5 h)", "5 days"): a minute passing is not a change.
export const steady = (text) => String(text || '').replace(/\b\d+(?:\.\d+)?\s?(?:s|sec|secs|seconds?|min|mins|minutes?|m|h|hours?|d|days?)\b/gi, '#').replace(/\s+/g, ' ').trim();
// FNV-1a, 32 bit, base 36: short, stable, no crypto needed (it only tells one wording from another on this phone)
export function hash(s) {
  let h = 0x811c9dc5; s = String(s);
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h.toString(36);
}
// The key a clear (or a thin bar) is kept under: id + a hash of its words and state (tone). A new or changed notice has a new key.
export const noticeKey = (n) => `${noticeId(n)}#${hash(n.tone + '|' + steady(n.text))}`;
// Every current notice with its key and how it shows now: a red bar is never cleared (truth rule), only made thin.
export function markNotices(list, cleared, thin) {
  return list.map((n) => {
    const key = noticeKey(n), broken = n.tone === 'broken';
    return { ...n, id: noticeId(n), key, cleared: !broken && cleared.has(key), thin: broken && thin.has(key) };
  });
}
// a kept list of keys, as stored and as read back from the phone: only strings count (anything else is no memory), the newest 60 at most
export const keysOf = (v) => (Array.isArray(v) ? v.filter((k) => typeof k === 'string').slice(-60) : []);
