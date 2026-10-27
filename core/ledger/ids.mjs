// @ts-check
// Work order ids and the joins between sources (build-way 3.1): the id comes from the Yard job (J312 -> WO-312, alias J312), the PR title
// prefix (WO-312: ...), or the branch (kitchen/J312). A PR that names no work order gets its own id (WO-PR-TIDE-21), so no open PR is
// missing from the ledger. Streams are upper-case names (contract common.stream).

const WO_RE = /^WO-[A-Z0-9]+(-[A-Z0-9]+)*$/;
export const isWo = (/** @type {unknown} */ s) => typeof s === 'string' && WO_RE.test(s) && s.length <= 40;

/** J312 -> WO-312 @param {string} job */
export const woOfJob = (job) => (/^J(\d+)$/.test(job) ? `WO-${job.slice(1)}` : null);
/** WO-312 -> J312 (only for ids imported from the Yard) @param {string} wo */
export const jobOfWo = (wo) => (/^WO-(\d+)$/.test(wo) ? `J${wo.slice(3)}` : null);
/** the WO id at the start of a PR title ("WO-312: ...", "WO-UPG-L1-1: ...") @param {string} title */
export function woOfTitle(title) { const m = /^\s*(WO-[A-Z0-9]+(?:-[A-Z0-9]+)*)\s*:/.exec(String(title || '')); return m && isWo(m[1]) ? m[1] : null; }
/** kitchen/J312 -> WO-312 @param {string} branch */
export function woOfBranch(branch) { const m = /^kitchen\/(J\d+)(?:$|[^\d])/.exec(String(branch || '')); return m ? woOfJob(m[1]) : null; }
/** JVonBorstel/tide -> tide (the prRef short name) @param {string} repo */
export const repoShort = (repo) => String(repo || '').split('/').pop()?.toLowerCase().replace(/[^a-z0-9._-]/g, '-').replace(/^[^a-z0-9]+/, '') || 'repo';
/** @param {string} repo @param {number} n */
export const prRef = (repo, n) => `${repoShort(repo)}#${n}`;
/** the id of a PR that names no work order @param {string} repo @param {number} n */
export const woOfPr = (repo, n) => `WO-PR-${repoShort(repo).toUpperCase().replace(/[^A-Z0-9]+/g, '-').replace(/^-|-$/g, '') || 'REPO'}-${n}`;

/** The stream of a PR by its branch (the prototype's rules), else of a WO id (WO-UPG-L1-3 -> UPG-L1). @param {string} branch @param {string} [wo] */
export function streamOf(branch, wo) {
  const b = String(branch || '');
  const rules = /** @type {Array<[RegExp, string]>} */ ([[/^s7[a-z]$/, 'ART'], [/^art[/-]/, 'ART'], [/^city-g\d/, 'CITY'], [/^port\//, 'PORT'], [/^(ms-td|multi-site)/, 'MULTI-SITE'],
    [/^rename\//, 'RENAME'], [/^kitchen\/J/, 'YARD'], [/^dependabot\//, 'DEPENDENCIES']]);
  for (const [re, s] of rules) if (re.test(b)) return s;
  const m = /^wo\/([a-z0-9]+(?:-[a-z]+\d*)?)/i.exec(b);
  if (wo && /^WO-[A-Z]/.test(wo) && !/^WO-PR-/.test(wo)) {   // WO-PR-<REPO>-<n> names a PR, not a stream const parts = wo.slice(3).split('-'); while (parts.length > 1 && /^\d+$/.test(parts[parts.length - 1])) parts.pop(); return parts.join('-').slice(0, 40); }
  if (m) return m[1].toUpperCase().replace(/[^A-Z0-9-]/g, '-').slice(0, 40);
  return 'OTHER';
}

/** RFC 3339 or null (a Yard time like 2026-10-26T18:26:55.5391286Z is kept; an unreadable one is null). @param {unknown} v */
export function isoOrNull(v) {
  if (typeof v !== 'string' || !v) return null;
  const t = Date.parse(v); if (Number.isNaN(t)) return null;
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(v) ? v : new Date(t).toISOString();
}

/** One line of plain words, clipped (contract common.text: 1..2000). @param {unknown} s @param {number} [n] */
export function text(s, n = 300) { const t = String(s ?? '').replace(/\s+/g, ' ').trim(); return t.length > n ? t.slice(0, n - 1) + '…' : t; }
