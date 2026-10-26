// Owns a small JSON Schema 2020-12 checker: only the keywords Tide's contracts use. Any other keyword is refused, so nothing is skipped quietly.
// Called by core/contracts/validate.mjs (makeChecker) and tests/core/contracts/test-contracts.mjs. Zero dependencies; Node 18 or later.

// Every keyword this checker understands. The first group only describes; the rest are checked.
export const KEYWORDS = new Set(['$schema', '$id', '$defs', '$comment', 'title', 'description', 'examples',
  '$ref', 'type', 'enum', 'const', 'properties', 'patternProperties', 'additionalProperties', 'required', 'maxProperties',
  'items', 'minItems', 'maxItems', 'uniqueItems', 'minLength', 'maxLength', 'pattern', 'minimum', 'maximum', 'format',
  'allOf', 'anyOf', 'oneOf', 'not', 'if', 'then', 'else']);
export const FORMATS = new Set(['date-time']);

const DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

export function typeOf(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
  return typeof v;
}
const isType = (v, t) => typeOf(v) === t || (t === 'number' && typeOf(v) === 'integer');

// Stable text for deep equality (const, enum, uniqueItems): object keys sorted.
function canon(v) {
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
  return JSON.stringify(v);
}
const show = (v) => { const s = JSON.stringify(v); return s.length > 60 ? s.slice(0, 57) + '...' : s; };

export function isDateTime(s) {
  const m = DATE_TIME.exec(s);
  if (!m) return false;
  const [y, mo, d, h, mi, se] = m.slice(1, 7).map(Number);
  const day = new Date(Date.UTC(y, mo - 1, d));
  return day.getUTCMonth() === mo - 1 && day.getUTCDate() === d && h < 24 && mi < 60 && se < 61;
}

function regex(ctx, p) {
  if (!ctx.regex.has(p)) ctx.regex.set(p, new RegExp(p, 'u'));
  return ctx.regex.get(p);
}

// A ref is "file#/json/pointer", "#/pointer" (same file) or "file" (its root). Returns the schema and the file later refs resolve in.
function resolve(ctx, ref, file) {
  const [f, frag = ''] = ref.split('#');
  const target = f || file;
  let node = ctx.schemas.get(target);
  if (node === undefined) throw new Error(`unresolved $ref "${ref}" in ${file}: no schema file ${target}`);
  for (const part of frag.split('/').filter(Boolean)) {
    node = node[part.replace(/~1/g, '/').replace(/~0/g, '~')];
    if (node === undefined) throw new Error(`unresolved $ref "${ref}" in ${file}: no "${part}"`);
  }
  return { schema: node, file: target };
}

function run(ctx, schema, value, file, path, errs) {
  if (schema === true) return;
  if (schema === false) { errs.push({ path, keyword: 'false', message: 'no value is allowed here' }); return; }
  for (const k of Object.keys(schema)) if (!KEYWORDS.has(k)) throw new Error(`unsupported keyword "${k}" in ${file}`);
  if (schema.$ref !== undefined) { const r = resolve(ctx, schema.$ref, file); run(ctx, r.schema, value, r.file, path, errs); }
  basics(schema, value, path, errs);
  if (typeOf(value) === 'object') objects(ctx, schema, value, file, path, errs);
  if (Array.isArray(value)) arrays(ctx, schema, value, file, path, errs);
  if (typeof value === 'string') strings(ctx, schema, value, file, path, errs);
  if (typeof value === 'number') numbers(schema, value, path, errs);
  combinators(ctx, schema, value, file, path, errs);
  conditional(ctx, schema, value, file, path, errs);
}

function basics(schema, value, path, errs) {
  if (schema.type !== undefined) {
    const types = [].concat(schema.type);
    if (!types.some((t) => isType(value, t))) errs.push({ path, keyword: 'type', message: `must be ${types.join(' or ')}, not ${typeOf(value)}` });
  }
  if (schema.const !== undefined && canon(value) !== canon(schema.const)) errs.push({ path, keyword: 'const', message: `must be ${show(schema.const)}` });
  if (schema.enum !== undefined && !schema.enum.some((e) => canon(e) === canon(value))) {
    errs.push({ path, keyword: 'enum', message: `must be one of ${schema.enum.map(show).join(', ')}; got ${show(value)}` });
  }
}

function objects(ctx, schema, value, file, path, errs) {
  for (const k of schema.required || []) if (!(k in value)) errs.push({ path: `${path}/${k}`, keyword: 'required', message: 'is missing' });
  const keys = Object.keys(value);
  if (schema.maxProperties !== undefined && keys.length > schema.maxProperties) {
    errs.push({ path, keyword: 'maxProperties', message: `has ${keys.length} keys; at most ${schema.maxProperties}` });
  }
  for (const k of keys) {
    let known = false;
    if (schema.properties && k in schema.properties) { known = true; run(ctx, schema.properties[k], value[k], file, `${path}/${k}`, errs); }
    for (const [p, sub] of Object.entries(schema.patternProperties || {})) {
      if (regex(ctx, p).test(k)) { known = true; run(ctx, sub, value[k], file, `${path}/${k}`, errs); }
    }
    if (known || schema.additionalProperties === undefined) continue;
    if (schema.additionalProperties === false) errs.push({ path: `${path}/${k}`, keyword: 'additionalProperties', message: 'is not an allowed key' });
    else run(ctx, schema.additionalProperties, value[k], file, `${path}/${k}`, errs);
  }
}

function arrays(ctx, schema, value, file, path, errs) {
  if (schema.minItems !== undefined && value.length < schema.minItems) errs.push({ path, keyword: 'minItems', message: `has ${value.length} items; at least ${schema.minItems}` });
  if (schema.maxItems !== undefined && value.length > schema.maxItems) errs.push({ path, keyword: 'maxItems', message: `has ${value.length} items; at most ${schema.maxItems}` });
  if (schema.uniqueItems && new Set(value.map(canon)).size !== value.length) errs.push({ path, keyword: 'uniqueItems', message: 'has repeated items' });
  if (schema.items !== undefined) value.forEach((v, i) => run(ctx, schema.items, v, file, `${path}/${i}`, errs));
}

function strings(ctx, schema, value, file, path, errs) {
  const n = [...value].length;
  if (schema.minLength !== undefined && n < schema.minLength) errs.push({ path, keyword: 'minLength', message: `is ${n} characters; at least ${schema.minLength}` });
  if (schema.maxLength !== undefined && n > schema.maxLength) errs.push({ path, keyword: 'maxLength', message: `is ${n} characters; at most ${schema.maxLength}` });
  if (schema.pattern !== undefined && !regex(ctx, schema.pattern).test(value)) errs.push({ path, keyword: 'pattern', message: `${show(value)} does not match ${schema.pattern}` });
  if (schema.format === undefined) return;
  if (!FORMATS.has(schema.format)) throw new Error(`unsupported format "${schema.format}" in ${file}`);
  if (!isDateTime(value)) errs.push({ path, keyword: 'format', message: `${show(value)} is not an RFC 3339 date-time` });
}

function numbers(schema, value, path, errs) {
  if (schema.minimum !== undefined && value < schema.minimum) errs.push({ path, keyword: 'minimum', message: `is ${value}; at least ${schema.minimum}` });
  if (schema.maximum !== undefined && value > schema.maximum) errs.push({ path, keyword: 'maximum', message: `is ${value}; at most ${schema.maximum}` });
}

// Each branch is checked into its own list. When none fits, the closest branch's errors are kept, so the reason stays specific.
function branches(ctx, list, value, file, path) {
  return list.map((s) => { const e = []; run(ctx, s, value, file, path, e); return e; });
}

function combinators(ctx, schema, value, file, path, errs) {
  for (const s of schema.allOf || []) run(ctx, s, value, file, path, errs);
  for (const kw of ['anyOf', 'oneOf']) {
    if (!schema[kw]) continue;
    const results = branches(ctx, schema[kw], value, file, path);
    const fits = results.filter((e) => !e.length).length;
    if (kw === 'oneOf' && fits > 1) errs.push({ path, keyword: 'oneOf', message: `fits ${fits} of the choices; exactly one is allowed` });
    if (fits) continue;
    const closest = results.reduce((a, b) => (b.length < a.length ? b : a));
    errs.push({ path, keyword: kw, message: `fits none of the ${results.length} choices` }, ...closest);
  }
  if (schema.not !== undefined && !branches(ctx, [schema.not], value, file, path)[0].length) {
    const what = schema.not.const !== undefined ? `must not be ${show(schema.not.const)}` : `has a shape that is not allowed here (${show(schema.not)})`;
    errs.push({ path, keyword: 'not', message: what });
  }
}

function conditional(ctx, schema, value, file, path, errs) {
  if (schema.if === undefined) return;
  const passed = !branches(ctx, [schema.if], value, file, path)[0].length;
  const next = passed ? schema.then : schema.else;
  if (next !== undefined) run(ctx, next, value, file, path, errs);
}

// Every keyword in every schema position is known, and every $ref resolves. Throws with the file and the reason otherwise.
function lintNode(ctx, node, file) {
  if (!node || typeof node !== 'object' || Array.isArray(node)) return;
  for (const k of Object.keys(node)) if (!KEYWORDS.has(k)) throw new Error(`unsupported keyword "${k}" in ${file}`);
  if (typeof node.$ref === 'string') resolve(ctx, node.$ref, file);
  if (node.format !== undefined && !FORMATS.has(node.format)) throw new Error(`unsupported format "${node.format}" in ${file}`);
  if (node.pattern !== undefined) regex(ctx, node.pattern);
  for (const k of ['properties', 'patternProperties', '$defs']) Object.values(node[k] || {}).forEach((n) => lintNode(ctx, n, file));
  for (const k of ['allOf', 'anyOf', 'oneOf']) (node[k] || []).forEach((n) => lintNode(ctx, n, file));
  for (const k of ['items', 'additionalProperties', 'not', 'if', 'then', 'else']) lintNode(ctx, node[k], file);
}

// schemas: a Map of file name (event.schema.json) to its parsed schema.
export function makeChecker(schemas) {
  const ctx = { schemas, regex: new Map() };
  return {
    check(file, value) {
      if (!schemas.has(file)) throw new Error(`no schema ${file}`);
      const errs = [];
      run(ctx, schemas.get(file), value, file, '', errs);
      return errs;
    },
    resolve: (ref, file) => resolve(ctx, ref, file),
    lint() { for (const [file, schema] of schemas) lintNode(ctx, schema, file); },
  };
}

export const formatError = (e) => `${e.path || '/'}: ${e.keyword}: ${e.message}`;
