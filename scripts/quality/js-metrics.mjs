// Owns the JavaScript half of scripts/quality/metrics.ps1: a tokenizer (comments, strings, template literals, regex literals) and a brace pass.
// Called by scripts/quality/metrics.ps1 as `node js-metrics.mjs <file>...`; prints one JSON array, one entry per file. No packages, no network.
import { readFileSync } from 'node:fs';

const KEYWORDS = new Set(['if', 'for', 'while', 'switch', 'catch', 'with', 'function', 'return', 'typeof', 'instanceof', 'in', 'of', 'new',
  'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await', 'try', 'finally', 'class', 'const', 'let', 'var', 'export', 'import', 'default']);
const CONTROL_PAREN = new Set(['if', 'for', 'while', 'switch', 'catch', 'with']);
const CONTROL_BARE = new Set(['else', 'try', 'finally', 'do', 'catch']);
// After one of these a '/' starts a regex literal; after an identifier, number, ')' or ']' it is a division.
const REGEX_AFTER_KEYWORD = new Set(['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await']);

// Tokens: { t: 'id' | 'num' | 'punc' | 'str', v, line }. Strings, template text and regex literals become one 'str' token; template
// ${...} expressions are tokenized as code (they can hold functions), their own braces are not emitted.
export function tokenize(src) {
  const out = [];
  const braces = []; // 'b' = code brace, 't' = template ${ ... }
  let i = 0, line = 1;
  const n = src.length;
  const isIdStart = (c) => /[A-Za-z_$]/.test(c) || c > '\x7f';
  const isId = (c) => /[\w$]/.test(c) || c > '\x7f';
  const prevAllowsRegex = () => {
    const p = out[out.length - 1];
    if (!p) return true;
    if (p.t === 'punc') return !(p.v === ')' || p.v === ']');
    if (p.t === 'id') return REGEX_AFTER_KEYWORD.has(p.v);
    return false;
  };
  // Reads template text from i (just after '`' or a closing '}' of ${...}); stops after the closing '`' or after '${'.
  const readTemplate = () => {
    const start = line;
    while (i < n) {
      const c = src[i];
      if (c === '\\') { if (src[i + 1] === '\n') line++; i += 2; continue; }
      if (c === '\n') line++;
      if (c === '`') { i++; out.push({ t: 'str', v: '`', line: start }); return; }
      if (c === '$' && src[i + 1] === '{') { i += 2; braces.push('t'); out.push({ t: 'str', v: '`', line: start }); return; }
      i++;
    }
  };
  while (i < n) {
    const c = src[i];
    if (c === '\n') { line++; i++; continue; }
    if (c === ' ' || c === '\t' || c === '\r') { i++; continue; }
    if (c === '/' && src[i + 1] === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '/' && src[i + 1] === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) { if (src[i] === '\n') line++; i++; }
      i += 2; continue;
    }
    if (c === '#' && i === 0 && src[1] === '!') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '"' || c === "'") {
      const start = line; i++;
      while (i < n && src[i] !== c && src[i] !== '\n') { if (src[i] === '\\') i++; i++; }
      i++; out.push({ t: 'str', v: c, line: start }); continue;
    }
    if (c === '`') { i++; readTemplate(); continue; }
    if (c === '/' && prevAllowsRegex()) {
      const start = line; i++;
      let cls = false;
      while (i < n && src[i] !== '\n') {
        const d = src[i];
        if (d === '\\') { i += 2; continue; }
        if (d === '[') cls = true; else if (d === ']') cls = false; else if (d === '/' && !cls) break;
        i++;
      }
      i++; while (i < n && isId(src[i])) i++;
      out.push({ t: 'str', v: '/', line: start }); continue;
    }
    if (isIdStart(c)) { let j = i + 1; while (j < n && isId(src[j])) j++; out.push({ t: 'id', v: src.slice(i, j), line }); i = j; continue; }
    if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(src[i + 1] || ''))) {
      let j = i + 1; while (j < n && /[\w.]/.test(src[j])) j++; out.push({ t: 'num', v: src.slice(i, j), line }); i = j; continue;
    }
    if (c === '=' && src[i + 1] === '>') { out.push({ t: 'punc', v: '=>', line }); i += 2; continue; }
    if (c === '{') { braces.push('b'); out.push({ t: 'punc', v: '{', line }); i++; continue; }
    if (c === '}') {
      const top = braces.pop();
      i++;
      if (top === 't') { readTemplate(); continue; }
      out.push({ t: 'punc', v: '}', line }); continue;
    }
    out.push({ t: 'punc', v: c, line }); i++;
  }
  return out;
}

// The name a function gets from what stands before index k (the start of its parameters or the 'function' keyword):
// `name = `, `name: `, `const name = async `. Empty when there is none (a callback).
function nameBefore(toks, k) {
  let j = k - 1;
  if (toks[j] && toks[j].v === 'async') j--;
  if (toks[j] && (toks[j].v === '=' || toks[j].v === ':') && toks[j - 1] && toks[j - 1].t === 'id') return toks[j - 1].v;
  return '';
}

// Index of the '(' that matches the ')' at index k, or -1.
function openParen(toks, k) {
  let depth = 0;
  for (let j = k; j >= 0; j--) {
    if (toks[j].t !== 'punc') continue;
    if (toks[j].v === ')') depth++;
    else if (toks[j].v === '(' && --depth === 0) return j;
  }
  return -1;
}

// What a '{' at index k opens: { kind: 'fn' | 'ctl' | 'blk', name }.
export function classify(toks, k) {
  const p = toks[k - 1];
  if (!p) return { kind: 'blk' };
  if (p.v === '=>') {
    const q = toks[k - 2];
    const start = q && q.v === ')' ? openParen(toks, k - 2) : k - 2;
    return { kind: 'fn', name: start >= 0 ? nameBefore(toks, start) : '' };
  }
  if (p.t === 'id' && CONTROL_BARE.has(p.v)) return { kind: 'ctl' };
  if (p.v !== ')') return { kind: 'blk' };
  const o = openParen(toks, k - 1);
  const b = toks[o - 1];
  if (!b) return { kind: 'blk' };
  if (b.t === 'id' && CONTROL_PAREN.has(b.v)) return { kind: 'ctl' };
  if (b.v === 'function') return { kind: 'fn', name: nameBefore(toks, o - 1) };
  if (b.v === '*' && toks[o - 2] && toks[o - 2].v === 'function') return { kind: 'fn', name: nameBefore(toks, o - 2) };
  if (b.t === 'id' && !KEYWORDS.has(b.v)) return { kind: 'fn', name: b.v }; // function name(, method name(, async name(, get name(
  if (b.v === ']') return { kind: 'fn', name: '' }; // computed method name
  return { kind: 'blk' };
}

// { functions: [{ name, start, lines }], maxNesting } for one source text. Nesting counts control blocks (if/for/while/switch/try/catch/
// else/do) inside the innermost function, like ESLint max-depth; a nested function starts again at 0.
export function measure(src) {
  const toks = tokenize(src);
  const stack = [];
  const functions = [];
  let maxNesting = 0;
  const depthNow = () => { let d = 0; for (let j = stack.length - 1; j >= 0 && stack[j].kind !== 'fn'; j--) if (stack[j].kind === 'ctl') d++; return d; };
  let anon = 0;
  toks.forEach((tk, k) => {
    if (tk.t !== 'punc') return;
    if (tk.v === '{') {
      const c = classify(toks, k);
      if (c.kind === 'fn' && !c.name) c.name = `<anonymous#${++anon}>`;
      stack.push({ ...c, start: tk.line });
      if (c.kind === 'ctl') maxNesting = Math.max(maxNesting, depthNow());
    } else if (tk.v === '}') {
      const f = stack.pop();
      if (f && f.kind === 'fn') functions.push({ name: f.name, start: f.start, lines: tk.line - f.start + 1 });
    }
  });
  return { functions, maxNesting, unbalanced: stack.length };
}

if (process.argv[1] && /js-metrics\.mjs$/.test(process.argv[1])) {
  const result = process.argv.slice(2).map((file) => {
    try { return { file, ...measure(readFileSync(file, 'utf8')) }; } catch (e) { return { file, error: String(e.message || e) }; }
  });
  process.stdout.write(JSON.stringify(result));
}
