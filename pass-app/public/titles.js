// The one place every Board screen gets a work order's title from (D-11): a human title, never a bare id alone, never raw markdown.
// Imported by app.js (nameOf, nameHtml and every list built on them); pure, no DOM, tested in node by pass-app/test-board-rows.mjs.

const cap = (s) => { s = String(s || ''); return s.charAt(0).toUpperCase() + s.slice(1); };
const human = (s) => String(s || '').replace(/[-_]+/g, ' ');
// a stored job id as people see it (J357 -> WO-0357); the same rule as app.js ticket
const ticket = (id) => 'WO-' + String(id || '').replace(/^J/, '').replace(/[^\w.-]/g, '').slice(0, 24).padStart(4, '0');
// an id and nothing else: J357, A16, B-48, GW-53, WO-0357
export const BARE_ID = /^(?:[A-Z]{1,3}-?\d{1,6}|WO-\d{1,6})$/i;

// Markdown out of a title: list bullets and numbers, headings, quotes, bold, italics, code ticks, links ([words](url) keeps the words),
// images and leftover emphasis marks; spaces collapsed. max cuts at a word with an ellipsis (Infinity: no cut). Empty in, '' out.
export function cleanTitle(text, max = Infinity) {
  let s = String(text ?? '').replace(/\r/g, '');
  s = s.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
  s = s.replace(/^\s*(?:[-*+]\s+|\d{1,3}[.)]\s+|#{1,6}\s+|>\s*)+/gm, '');
  s = s.replace(/(\*\*|__)(.+?)\1/g, '$2').replace(/(^|[\s(])[*_]([^*_\s][^*_]*?)[*_](?=$|[\s).,:;!?])/g, '$1$2').replace(/`+([^`]*)`+/g, '$1');
  s = s.replace(/\*{2,}|_{2,}|`+/g, '').replace(/\s+/g, ' ').trim();
  if (s.length > max) s = s.slice(0, Math.max(1, max - 1)).replace(/\s+\S*$/, '').replace(/[\s,;:.-]+$/, '') + '…';
  return s;
}
// a goal or name as one title line: its first markdown heading if it has one, else its first non-empty line
export function firstLine(text) {
  const lines = String(text ?? '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  return lines.find((l) => /^#{1,6}\s+\S/.test(l)) || lines[0] || '';
}
// plain words for a phone: the first clause without file paths ("kitchen/stations/lint.ps1" reads as "lint"), at most ~60 characters.
// A name the Yard already cut ("... at Example Co (Remote, ...") loses its open bracket or its cut-off word: never half a word.
export function plainWords(text) {
  let s = cleanTitle(firstLine(text)).replace(/\s*\(Idea I\d+:[\s\S]*$/, '');
  let cut = /(?:\.{3}|…)$/.test(s); s = s.replace(/\s*(?:\.{3}|…)$/, '');
  if (cut && /\([^)]*$/.test(s)) { s = s.replace(/\s*\([^)]*$/, ''); cut = false; }
  if (cut && /\s/.test(s)) s = s.replace(/\s+\S*$/, '') + '…';
  s = s.replace(/[\s,;:-]+$/, '');
  s = s.replace(/(?:[\w.-]+[\\/])+([\w-]+)\.(?:ps1|psm1|mjs|js|json|md|css|html)\b/g, '$1').replace(/\b([\w-]+)\.(?:ps1|psm1|mjs|json|md)\b/g, '$1');
  s = s.split(/(?<=[a-z0-9)])[.;:]\s|\s\(?\d\)\s/)[0].trim();
  if (s.length > 60) s = s.slice(0, 58).replace(/\s+\S*$/, '') + '…';
  return cap(s);
}
// A detail (a failure reason, an alert, a step's note) as the main words of a line (task 30, D-11): its first line, Windows and repo paths
// read as the file's name ("C:\x\kitchen\stations\lint.ps1" and "kitchen/stations/lint.ps1" read "lint"), JSON objects left out, markdown
// marks dropped, at most `max` characters. The full text stays one tap away (the work order's sheet, its History and Logs).
const EXT = 'ps1|psm1|mjs|cjs|js|ts|jsonl|json|md|css|html|py|txt|ya?ml|log';
export function plainDetail(text, max = 140) {
  let s = firstLine(text);
  const urls = []; s = s.replace(/https?:\/\/\S+/g, (u) => `\u0000${urls.push(u) - 1}\u0000`);   // links stay as they are
  for (let i = 0; i < 3 && /\{[^{}]*\}/.test(s); i++) s = s.replace(/\{[^{}]*\}/g, ' ');   // JSON objects, inside out
  s = s.replace(/\[\s*\{[^\]]*\]/g, ' ');
  s = s.replace(/\b[A-Za-z]:[\\/](?:[^\\/\s"']+[\\/])*([^\\/\s"']+)/g, '$1').replace(/(?:\\\\|\.{1,2}[\\/])?(?:[\w@.-]+\\)+([\w.-]+)/g, '$1');
  s = s.replace(new RegExp(`(?:\\.{1,2}/)?(?:[\\w@.-]+/)+([\\w.-]+\\.(?:${EXT}))\\b`, 'g'), '$1').replace(new RegExp(`\\b([\\w-]+)\\.(?:${EXT})\\b`, 'g'), '$1');
  s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => urls[Number(i)]);
  s = cleanTitle(s).replace(/\s+([,.;:)])/g, '$1').replace(/\(\s*\)/g, '').replace(/\s{2,}/g, ' ').trim();
  return s.length > max ? s.slice(0, Math.max(1, max - 1)).replace(/\s+\S*$/, '') + '…' : s;
}
// "improve: split kitchen.ps1" reads as a kind (small label) and the rest
export function splitName(name) {
  const m = /^([a-z][\w-]{1,15}):(?:\s+([\s\S]*))?$/i.exec(String(name || ''));
  return m ? { recipe: m[1].toLowerCase(), kind: cap(human(m[1]).toLowerCase()), rest: m[2] || '' } : { recipe: '', kind: '', rest: String(name || '') };
}
// what an order whose name is only an id is about, in words, by its Spec (the id stays as the reference, never alone)
const BY_SPEC = {
  diagnose: (ref) => `Why ${ref} failed`,
  'apply-prep': (ref) => `Application prep ${ref}`,
  'roadmap-item': (ref) => `Blueprint floor ${ref}`,
  tailor: () => 'Tailored draft',
};
const asRef = (s) => (/^J\d{1,6}$/i.test(s) ? ticket(s.toUpperCase()) : s);
// A work order's title: { kind, text }. The idea's short title (label) when the server has one, else the name's first heading or line
// in plain words; an id alone (or nothing) becomes words from its Spec, else "Work order <id>" (its own number when it has no words).
export function titleOf(j) {
  const n = splitName(j?.name); const recipe = String(j?.recipe || n.recipe || '').toLowerCase();
  const raw = String(j?.label || ''); const label = cleanTitle(firstLine(/^\w+(-\w+)+$/.test(raw) ? raw.replace(/-/g, ' ') : raw));   // a slug reads as words
  let text = label ? cap(label) : plainWords(n.rest);
  if (!text || BARE_ID.test(text)) {
    const ref = text ? asRef(text) : ''; const spec = BY_SPEC[recipe];
    text = spec && (ref || recipe === 'tailor') ? spec(ref) : `Work order ${ref || ticket(j?.id)}`;
  }
  return { kind: n.kind, text };
}
