// What a person reads on the Board, as text: the string literals and template text of the Board's scripts and the text of index.html,
// with markup plumbing taken out (tag names; class, id, data-*, aria-labelledby/-controls/-describedby, for, name, href, src values).
// Comments are not strings, so they never count. Used by test-scene.mjs (SiteWordsEverywhere: no kitchen word on screen).
export const KITCHEN_ON_SCREEN = /\b(chefs?|toques?|kitchens?|tickets?|dish(es)?|order up|cloches?|sous chef)\b/i;
// (an attribute cut by a ${...} ends at the cut; a file name such as kitchen.repo.json is a code name, shown as the file it is)
const PLUMBING = /\s(class|id|for|name|href|src|role|type|aria-(labelledby|controls|describedby|haspopup)|data-[\w-]+)="[^"]*("|$)|<\/?[a-z][\w-]*|\sdata-[\w-]+|\b[\w.-]+\.(json|ps1|js|mjs|md)\b/gi;
// every string literal in JS source ('..', "..", and each static part of a `..${..}..` template, nested ones too); comments and
// regex literals skipped
export function stringsOf(src) {
  const out = [], tpl = []; let i = 0, prev = '';
  const readTpl = (start) => {   // template text from start to the closing ` or the next ${
    let j = start, s = '';
    while (j < src.length) {
      const d = src[j];
      if (d === '\\') { s += src[j + 1]; j += 2; continue; }
      if (d === '`') { out.push({ at: start, text: s }); return { j: j + 1, open: false }; }
      if (d === '$' && src[j + 1] === '{') { out.push({ at: start, text: s }); return { j: j + 2, open: true }; }
      s += d; j++;
    }
    out.push({ at: start, text: s }); return { j, open: false };
  };
  while (i < src.length) {
    const c = src[i], n = src[i + 1];
    if (c === '/' && n === '/') { i = src.indexOf('\n', i); if (i < 0) break; continue; }
    if (c === '/' && n === '*') { i = src.indexOf('*/', i + 2); if (i < 0) break; i += 2; continue; }
    if (c === '/' && (prev === '' || '(,=:[!&|?{};+-*%<>~^'.includes(prev) || /\b(return|typeof|case|of|in)$/.test(src.slice(Math.max(0, i - 8), i).trimEnd()))) {   // a regex literal
      let j = i + 1, cls = false;
      while (j < src.length && src[j] !== '\n') { const d = src[j]; if (d === '\\') { j += 2; continue; } if (d === '[') cls = true; else if (d === ']') cls = false; else if (d === '/' && !cls) break; j++; }
      i = j + 1; prev = ')'; continue;
    }
    if (c === '`') { const r = readTpl(i + 1); i = r.j; if (r.open) tpl.push(0); prev = r.open ? '(' : ')'; continue; }
    if (tpl.length && c === '{') tpl[tpl.length - 1]++;
    if (tpl.length && c === '}') {
      if (tpl[tpl.length - 1] === 0) { tpl.pop(); const r = readTpl(i + 1); i = r.j; if (r.open) tpl.push(0); prev = r.open ? '(' : ')'; continue; }
      tpl[tpl.length - 1]--;
    }
    if (c === "'" || c === '"') {
      let j = i + 1, s = '';
      while (j < src.length && src[j] !== c && src[j] !== '\n') { if (src[j] === '\\') { s += src[j + 1]; j += 2; continue; } s += src[j]; j++; }
      out.push({ at: i, text: s }); i = j + 1; prev = ')'; continue;
    }
    if (!/\s/.test(c)) prev = c;
    i++;
  }
  return out;
}
// the words a person can read: a string with a space or a capital (a sentence, a label), its markup plumbing removed
export const visible = (s) => (/[ A-Z]/.test(s) ? s.replace(PLUMBING, ' ') : '');
// file:line "word" for every kitchen word on screen; allow: exact strings that are not shown (each one needs its reason where it is passed)
export function kitchenHits(src, file, allow = []) {
  const lineOf = (at) => src.slice(0, at).split('\n').length;
  const strs = file.endsWith('.html') ? [{ at: 0, text: src.replace(/<!--[\s\S]*?-->/g, '').replace(/<(script|style)[\s\S]*?<\/\1>/gi, '') }] : stringsOf(src);
  return strs.map((s) => ({ ...s, v: file.endsWith('.html') ? s.text.replace(PLUMBING, ' ') : visible(s.text) }))
    .filter((s) => KITCHEN_ON_SCREEN.test(s.v) && !allow.includes(s.text))
    .map((s) => `${file}:${lineOf(s.at)} "${s.v.match(KITCHEN_ON_SCREEN)[0]}"`);
}
