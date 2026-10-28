// @ts-check
// Everything the ledger writes for others to read goes through here: work.json and ledger.next.json (the Board reads them, and the
// Board is reached from the phone), every --json answer and error line of cli.mjs, and any record that would leave this PC (an API
// answer, a cloud task, a PR body). tide.db itself keeps the raw facts; it never leaves the PC.
//   - redactText: free text (goals, titles, why, proof, notes) loses this PC's paths (also after a colon, in file:/// URLs, and with
//     spaces), email addresses, private host names and addresses (IPv4 and the tailnet's fd7a: IPv6), and the private words of the state
//     folder's list (private repo names, private topics): each is replaced by a fixed marker. Secrets (tokens, keys, bearer headers,
//     long hex or base64 values in key=value form, also as JSON "key":"value"; a 40 or 64 hex git id under sha, commit, head, tree and the
//     like stays) and the repo part of a git remote that is not the public repo (any case; git@, ssh:// with a port, git://, https, the
//     api.github.com/repos and raw.githubusercontent.com forms; a bare Owner/repo after gh repo clone, --repo, -R, repo:, as X#12 or
//     X@sha, with the public owner, or shaped like one) are found by pattern, without the list. A plain lower-case owner/repo with no
//     cue is not guessed: it needs the private words list.
//   - a private work order (wo.created private) shows no goal, no reason, no card question: only "a private work order" (as the City
//     does, docs/changes/city-g2).
//   - publicEvent: an x.* event's data, and every event of a private order, is dropped whole; then core/contracts/public.mjs toPublic
//     strips local paths from the x-local-only fields (proof). publicRow: the same for a row.
// The private words list is <state>\ledger-private-words.json (a JSON list; core/ledger/ledger-private-words.example.json shows the
// shape). When it is missing, everything else is still redacted and the build says so in a warning (fail safe, never silent).
import fs from 'node:fs';
import { toPublic, LOCAL_PATH } from '../contracts/public.mjs';
import { CONTRACT_V } from './store.mjs';

export const MARK = { path: '<local path>', email: '<email>', host: '<private host>', word: '<private>', secret: '<secret>', repo: '<private repo>', order: 'a private work order', ask: 'a private question' };
// a path on this PC: a file:/// URL; a drive path (also right after a colon, as in cwd:C:\...); a \\host\share path; a home or system
// path. It runs to the end of the token, spaces included (C:\Program Files\...), and stops at a quote, a bracket, < > |, ; or a newline.
const PATH = /(?:file:\/\/\/?[^\s"'<>|]+)|(?:(?<![A-Za-z0-9])[A-Za-z]:[\\/]|\\\\[^\s\\/"'<>|]+[\\/]|(?<![\w.~-])~[A-Za-z0-9._-]*[\\/]|(?<![\w:/.~-])\/(?:home|Users|root|srv|var|tmp|mnt|opt|etc|private|Volumes)\/)[^"'<>|;()[\]{}\r\n]*?(?=$|["'<>|;()[\]{}\r\n]|,\s|\s(?:and|or|for|to|in|on|at|with|from|by)\s|\.\s|\s[-:]\s)/gm;
// bounded parts, so a long run of letters is linear, not quadratic
const EMAIL = /(?<![A-Za-z0-9._%+-])(?![Gg][Ii][Tt]@)[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24}(?![A-Za-z0-9-])/g;
// tailnet and home-network names (not a file name like appsettings.local.json), private IPv4 (10/8, 172.16/12, 192.168/16, 100.64/10
// used by Tailscale) and unique-local IPv6 (fd00::/8; Tailscale uses fd7a:115c:a1e0::/48)
const HOST = /\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:ts\.net|local|lan|internal|home\.arpa)\b(?![.\w-])/gi;
const IP4 = /\b(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d{1,3}\.\d{1,3}\b/g;
const IP6 = /\bfd[0-9a-f]{2}:[0-9a-f:]{2,}(?:%\w+)?/gi;
// a tailnet's own name (tail1a2b3c, tail-1a2b3c): tail, an optional dash, and 4+ hex characters with at least one digit, so plain words
// that happen to be made of a to f (tail-fade, tail-dead, tailadded) stay. *.ts.net names are caught by HOST.
const TAILNET = /\btail-?(?=[0-9a-f]*\d)[0-9a-f]{4,}\b/gi;
// secrets by shape: GitHub tokens, sk- keys (Anthropic, OpenAI and the like), Slack tokens, JWTs, Bearer/Basic headers, and a long hex
// or base64 value given to a key (key=..., token: ...). The key stays, so the text still says what was there.
// keys that name a git object id: their 40 or 64 hex value is a commit, tree or digest, not a secret (a ledger proof carries them)
const GIT_ID_KEY = /(?:^|[^A-Za-z0-9])(?:sha\d*|commit|head|tree|rev|revision|hash|oid|parent|tip|base|merge|digest|checksum)$/i;
const GIT_ID_KEY_CAMEL = /[a-z0-9](?:Sha\d*|Commit|Head|Tree|Rev|Revision|Hash|Oid|Parent|Tip|Base|Merge|Digest|Checksum)$/;
const SECRETS = /** @type {Array<[RegExp, string | ((...a: any[]) => string)]>} */ ([
  [/\b(?:gh[pousr]_[A-Za-z0-9]{20,255}|github_pat_[A-Za-z0-9_]{20,255})\b/g, '<secret>'],
  [/\bsk-[A-Za-z0-9][A-Za-z0-9_-]{15,}/g, '<secret>'],
  [/\bxox[abposr]-[A-Za-z0-9-]{10,}/g, '<secret>'],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, '<secret>'],
  // a header value or a key's value counts as a secret when it has a digit or is 20+ characters (so "token expired" stays as written)
  [/\b(Bearer|Basic|token)\s+(?=[A-Za-z0-9._~+/=-]*\d|[A-Za-z0-9._~+/=-]{20,})[A-Za-z0-9._~+/=-]{12,}/gi, '$1 <secret>'],
  // key=value, key: value, and the JSON forms "key":"value" and \"key\":\"value\" (a quote may sit between the key and the colon)
  [/\b((?:[A-Za-z_][A-Za-z0-9_.-]{0,40}?)?(?:key|token|secret|password|passwd|pwd|auth|credential)s?)((?:\\?["'])?\s*[:=]\s*(?:\\?["'])?)(?=[^\s"']*\d|[^\s"']{20,})(?:[^\s"'\\]|\\(?!["'])){8,}/gi, '$1$2<secret>'],
  // a long hex or base64 value given to any key, except a git id (exactly 40 or 64 hex) given to a key that names one (sha=, commit:, head=, tree:)
  [/\b([A-Za-z_][A-Za-z0-9_.-]{0,40})((?:\\?["'])?\s*[:=]\s*(?:\\?["'])?)([0-9a-fA-F]{32,}|[A-Za-z0-9+/]{40,}={0,2})(?![A-Za-z0-9+/=])/g,
    (/** @type {string} */ m, /** @type {string} */ key, /** @type {string} */ sep, /** @type {string} */ val) => (GIT_ID_KEY.test(key) || GIT_ID_KEY_CAMEL.test(key)) && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(val) ? m : `${key}${sep}<secret>`],
]);
/** The one public repo: a remote of any other repo loses its owner/name. */
export const PUBLIC_REPOS = ['vonborstel-j/tide'];
const isPublicRepo = (/** @type {string} */ p) => PUBLIC_REPOS.includes(p.replace(/\.git$/i, '').toLowerCase());
// a git remote in URL form: ssh://[user@]host[:port]/path, git://, git+https://, https://[user@]host/path, in any case. What counts as the
// repo path depends on the host (see urlRemote); the rest of the URL (a tail like /pull/7, a query) stays. The URL ends at a space, a
// quote, a bracket, > , ; | or *. Any user part but "git" is dropped (it may be a name or a token).
const REMOTE_URL = /(?<![\w+.-])((?:ssh|git|git\+ssh|ssh\+git|git\+https?|https?):\/\/)(?:([^\s/@"'<>]*)@)?([\w.-]+)(:\d{1,5})?\/([^\s"'<>)\]}|*,;]*)/gi;
// scp form: git@host:owner/repo.git, also nested (group/sub/repo); not the port form git@host:2222/..., not the tail of ssh://git@host
const REMOTE_SCP = /(?<![\w+.-]|\/\/)(git)@([\w.-]+):(?!\d+\/)([\w.-]+(?:\/[\w.-]+)*)/gi;
/** @param {string} m @param {string} scheme @param {string | undefined} user @param {string} host @param {string | undefined} port @param {string} rest */
function urlRemote(m, scheme, user, host, port, rest) {
  const h = host.toLowerCase(), sc = scheme.toLowerCase();
  const tm = /[.:!?]+$/.exec(rest); const punct = tm ? tm[0] : ''; if (tm) rest = rest.slice(0, -punct.length);
  const q = rest.search(/[?#]/); const pathPart = q < 0 ? rest : rest.slice(0, q), suffix = q < 0 ? '' : rest.slice(q);
  const segs = pathPart.split('/');
  const gitEnd = segs.findIndex((x) => /\.git$/i.test(x));
  let skip = 0, n = 0;
  if (/^(?:www\.)?(?:github\.com|bitbucket\.org)$/.test(h) || h === 'raw.githubusercontent.com' || h === 'codeload.github.com') n = 2;
  else if (h === 'api.github.com') { if (segs[0] !== 'repos') return m; skip = 1; n = 2; }
  else if (/^(?:www\.)?gitlab\.com$/.test(h)) { const dash = segs.indexOf('-'); n = gitEnd >= 0 ? gitEnd + 1 : dash >= 0 ? dash : segs.filter(Boolean).length; }
  else if (h === 'dev.azure.com') { const i = segs.indexOf('_git'); if (i < 2) return m; n = i + 2; }
  else if (/^(?:ssh|git|git\+ssh|ssh\+git)$/.test(sc)) n = gitEnd >= 0 ? gitEnd + 1 : segs.filter(Boolean).length;
  else if (gitEnd >= 0) n = gitEnd + 1;     // any other host: only a URL that names a .git repo is a remote; ordinary links stay
  if (n < 1 || skip + n > segs.length) return m;
  const repoSegs = segs.slice(skip, skip + n); if (repoSegs.some((x) => !x)) return m;
  const keepUser = user !== undefined && user.toLowerCase() === 'git', pub = isPublicRepo(repoSegs.join('/'));
  if (pub && (user === undefined || keepUser)) return m;
  const shown = pub ? repoSegs.join('/') : `${MARK.repo}${/\.git$/i.test(repoSegs[n - 1]) ? '.git' : ''}`;
  return `${scheme}${keepUser ? `${user}@` : ''}${host}${port || ''}/${[...segs.slice(0, skip), shown, ...segs.slice(skip + n)].join('/')}${suffix}${punct}`;
}
/** @param {string} t */
function redactRemotes(t) {
  return t.replace(REMOTE_URL, urlRemote).replace(REMOTE_SCP, (m, user, host, path) => {
    const tm = /\.+$/.exec(path); const punct = tm ? tm[0] : ''; const p = tm ? path.slice(0, -punct.length) : path;
    if (!p || isPublicRepo(p)) return m;
    return `${user}@${host}:${MARK.repo}${/\.git$/i.test(p) ? '.git' : ''}${punct}`;
  });
}
// a repo named in plain text (not in a URL): after a command or flag that takes one (gh repo clone X, --repo X, -R X, repo: X, repos/X),
// as an issue or commit reference (X#12, X@abc1234), with the public owner (VonBorstel-J/anything but the public repo), or shaped like
// one: a Capitalized owner and a repo name with a dash, dot, underscore or digit (Example/private-repo). A plain lower-case owner/repo
// with no cue (a path like core/ledger) is not guessed: the private words list covers those.
const BARE_CUE = /((?:\bgh\s+repo\s+(?:clone|view|fork|create|delete|sync|edit|archive|rename|set-default)\s+|--repo(?:sitory)?[=\s]+|(?<![\w-])-R\s+|\brepo(?:sitory)?\s*[:=]\s*|\brepos\/)["']?)([A-Za-z0-9][\w-]{0,38})\/([\w.-]+?)(?![\w-]|\.[\w-])/gi;
const BARE_REF = /(?<![\w./\:@#-])([A-Za-z0-9][\w-]{0,38})\/([\w.-]+?)(?=#\d|@[0-9a-f]{7,40}(?![\w.@-]))/gi;
const BARE_OWNER = /(?<![\w./\:@#-])(vonborstel-j)\/([\w.-]+?)(?![\w-]|\.[\w-])/gi;
const BARE_SHAPE = /(?<![\w./\:@#-])([A-Z](?=[A-Za-z0-9-]*[a-z])[A-Za-z0-9-]{1,38})\/((?=[\w.-]*[-_.\d])[A-Za-z0-9][\w.-]*?)(?![\w-]|\.[\w-])/g;
const FILE_EXT = /\.(?:md|json|jsonl|mjs|cjs|js|ts|tsx|ps1|psm1|txt|ya?ml|html?|css|db|cmd|sh|py|log|csv|xml|toml|lock|png|jpg|svg)$/i;
/** @param {string} t */
function redactBareRepos(t) {
  const repl = (/** @type {string} */ m, /** @type {string} */ pre, /** @type {string} */ o, /** @type {string} */ r) => (isPublicRepo(`${o}/${r}`) ? m : `${pre}${MARK.repo}`);
  return t.replace(BARE_CUE, repl)
    .replace(BARE_REF, (m, o, r) => repl(m, '', o, r))
    .replace(BARE_OWNER, (m, o, r) => repl(m, '', o, r))
    .replace(BARE_SHAPE, (m, o, r) => (FILE_EXT.test(r) ? m : repl(m, '', o, r)));
}
const esc = (/** @type {string} */ s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
export const PRIVATE_WORDS_FILE = 'ledger-private-words.json';

/**
 * The private words: a JSON list in the state folder (never in the repo). Missing or unreadable: no words, and `warning` says so.
 * @param {string | undefined} file a JSON array of strings, or { "words": [...] }
 * @returns {{ words: string[], why: string, warning: string | null }}
 */
export function readPrivateWords(file) {
  const warn = (/** @type {string} */ why) => ({ words: [], why, warning: `WARNING: ${why}${file ? ` (${file})` : ''}: private repo names and private topics are NOT redacted; paths, emails, hosts, addresses and private orders still are. Copy core/ledger/ledger-private-words.example.json there and fill it in.` });
  if (!file || !fs.existsSync(file)) return warn('no private words list');
  try {
    const d = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
    const list = Array.isArray(d) ? d : Array.isArray(d?.words) ? d.words : null;
    if (!list) return warn('the private words list is not a JSON list');
    return { words: list.map((w) => String(w).trim()).filter((w) => w.length >= 2), why: '', warning: null };
  } catch { return warn('the private words list is not JSON'); }
}

/** @param {{ privateWords?: string[] }} [o] @returns {(s: string) => string} */
export function makeRedactor(o = {}) {
  const words = [...new Set((o.privateWords || []).filter(Boolean))].sort((a, b) => b.length - a.length);
  const W = words.length ? new RegExp(`(?<![A-Za-z0-9])(?:${words.map(esc).join('|')})(?![A-Za-z0-9])`, 'gi') : null;
  return (s) => {
    let t = redactRemotes(String(s));   // before e-mails: git@host would read as one
    for (const [re, to] of SECRETS) t = t.replace(re, /** @type {any} */ (to));
    t = t.replace(PATH, MARK.path).replace(new RegExp(LOCAL_PATH.source, 'g'), MARK.path)
      .replace(EMAIL, MARK.email).replace(HOST, MARK.host).replace(IP4, MARK.host).replace(IP6, MARK.host).replace(TAILNET, MARK.host);
    t = redactBareRepos(t);
    if (W) t = t.replace(W, MARK.word);
    return t;
  };
}

/** Every string in a value, redacted (keys are kept). @param {any} v @param {(s: string) => string} redact @returns {any} */
export function redactDeep(v, redact) {
  if (typeof v === 'string') return redact(v);
  if (Array.isArray(v)) return v.map((x) => redactDeep(x, redact));
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, redactDeep(x, redact)]));
  return v;
}

/**
 * The private work orders of a view: their ids, Yard aliases and decision ids, and the private words their events imply (their repo
 * names).
 * @param {any} view a buildView answer (with internal.fold)
 */
export function privateOf(view) {
  const ids = new Set(), aliases = new Set(), words = new Set(), decisions = new Set();
  for (const w of view.internal?.fold?.wos?.values?.() || []) {
    if (!w.private) continue;
    ids.add(w.id); if (w.alias) aliases.add(w.alias); for (const d of w.decisions || []) decisions.add(d);
    const rp = String(w.yard?.repoPath || '').split(/[\\/]/).filter(Boolean).pop(); if (rp) words.add(rp);
    const gh = String(w.repo || '').split('/').pop(); if (gh) words.add(gh);
  }
  return { ids, aliases, decisions, words: [...words] };
}

/** A reason with its words removed: "set aside: <reason>" -> "set aside: (private)". @param {string | null} s */
const maskReason = (s) => (s ? (s.includes(':') ? `${s.slice(0, s.indexOf(':'))}: (private)` : '(private)') : s);
/** A card of a private order: no question, no why, no note, no mock-up titles. @param {any} d */
const maskDecision = (d) => ({ ...d, ask: MARK.ask, ...(d.why != null ? { why: null } : {}), note: d.note == null ? null : '(private)', ...(d.variants ? { variants: d.variants.map((/** @type {any} */ x) => ({ ...x, title: MARK.order })) } : {}) });

/**
 * work.json (and the --json answers built from it), ready to share: a private order shows no goal, reason or card question; every
 * string is redacted.
 * @param {any} work the view without internal @param {ReturnType<typeof privateOf>} priv @param {(s: string) => string} redact
 */
export function shareWork(work, priv, redact) {
  const rows = work.rows.map((/** @type {any} */ r) => (priv.ids.has(r.id) ? { ...r, goal: MARK.order, blockedOn: maskReason(r.blockedOn), next: maskReason(r.next), branch: null, pr: null } : r));   // a private order's branch and PR name its work too (review of tide#40, F1)
  const queue = (/** @type {any[]} */ q) => q.map((c) => (priv.decisions.has(c.decision?.id) || (c.decision?.wo && priv.ids.has(c.decision.wo)) ? { ...c, goal: MARK.order, decision: maskDecision(c.decision) } : c));
  const flags = (work.flags || []).map((/** @type {any} */ f) => (f.wo && priv.ids.has(f.wo) ? { ...f, detail: `${f.wo}: ${MARK.order} (${f.flag})` } : f));
  const streams = (work.streams || []).map((/** @type {any} */ s) => ({ ...s, blockedOn: s.blockedOn && rows.some((/** @type {any} */ r) => priv.ids.has(r.id) && r.stream === s.stream && work.rows.find((/** @type {any} */ x) => x.id === r.id)?.blockedOn === s.blockedOn) ? maskReason(s.blockedOn) : s.blockedOn }));
  return redactDeep({ ...work, rows, flags, streams, queue: queue(work.queue || []), queueAll: queue(work.queueAll || []) }, redact);
}

/**
 * ledger.next.json, ready to share: a private order's item, chain and flags show no title or reason; every string is redacted.
 * @param {any} doc exportLedgerJson's answer @param {ReturnType<typeof privateOf>} priv @param {(s: string) => string} redact
 */
export function shareLedger(doc, priv, redact) {
  const isPriv = (/** @type {any} */ x) => priv.ids.has(String(x.wo || '')) || priv.aliases.has(String(x.id || '')) || (x.kind === 'idea' && (x.chain || []).some((/** @type {any} */ c) => priv.aliases.has(String(c.id))));
  const items = doc.items.map((/** @type {any} */ x) => (isPriv(x) ? { ...x, title: MARK.order, why: maskReason(x.why), chain: (x.chain || []).map((/** @type {any} */ c) => ({ ...c, note: '' })) } : x));
  const privIds = new Set(doc.items.filter(isPriv).map((/** @type {any} */ x) => String(x.id)));
  const flags = (doc.flags || []).map((/** @type {any} */ f) => (priv.decisions.has(String(f.id)) || priv.ids.has(String(f.id)) || privIds.has(String(f.id)) ? { ...f, say: `${f.id}: ${MARK.order} (${f.rule})` } : f));
  return redactDeep({ ...doc, items, flags }, redact);
}

/**
 * An event, ready to share: an x.* event's data and every event of a private order lose their data whole.
 * @param {any} e an event @param {{ private?: boolean }} [o] @returns {{ doc: any, stripped: string[] }}
 */
export function publicEvent(e, o = {}) {
  const local = /^x\./.test(String(e?.kind || '')) || o.private === true;
  const base = local ? { ...e, data: {} } : e;
  const r = toPublic('event', { v: CONTRACT_V, ...base });
  return { doc: r.doc, stripped: local ? ['/data', ...r.stripped] : r.stripped };
}

/** @param {any} row @returns {{ doc: any, stripped: string[] }} */
export function publicRow(row) { return toPublic('row', row); }
