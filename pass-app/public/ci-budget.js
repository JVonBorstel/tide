// The Board's CI budget lines (multi-site design TD-11, Q8 = yes): this month's CI runs and billed minutes per Site, and why new PRs wait.
// Imported by app.js (renderBanners, ciBudgetBanners); pure text, no DOM, tested in node by tests/Test-PassApp.ps1. Existing .banner look.
import { esc } from './scene.js';

const num = (n) => Number(n).toLocaleString('en-US');
const defaultDay = (iso) => new Date(iso).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
// one Site in the summary line: runs and minutes, "at least" while measuring, unknown with the reason (never a zero)
function siteWords(s) {
  const name = s.code ? `Site ${esc(s.code)}` : 'Unassigned';
  if (s.state === 'none') return `${name}: no Tower on GitHub`;
  if (s.state === 'unknown') return `${name}: unknown (${esc(s.why || 'GitHub could not be read')})${s.minutesAtLeast != null ? `, at least ${num(s.minutesAtLeast)} min` : ''}`;
  const of = s.budget === 'unlimited' ? ' (no limit)' : s.budget != null ? ` of ${num(s.budget)}` : '';
  const min = s.state === 'partial' ? `at least ${num(s.minutesAtLeast)}${of} min (still measuring)` : `${num(s.minutes)}${of} min`;
  return `${name}: ${num(s.runs)} runs, ${min}`;
}

// v: state.ciBudget from the server (pass-app/server.mjs ciBudgetView), or null. An over-budget Site is an alarm banner that says new pull
// requests wait and what lets them go; then one calm line with every Site's count and the account's private pool.
export function ciBudgetBanners(v, { day = defaultDay } = {}) {
  if (!v || !Array.isArray(v.sites)) return [];
  const out = [];
  for (const s of v.sites) {
    if (!s.over) continue;
    out.push(`<div class="banner" data-ci-budget="over">Site ${esc(s.code)} is over its CI budget: at least ${num(s.minutesAtLeast)} of ${num(s.budget)} billed minutes this month. New pull requests for it wait until ${v.monthEnds ? esc(day(v.monthEnds)) : 'the new month'}, a bigger ciMinutesPerMonth in kitchen.json, or a public Tower. Open ones go on.</div>`);
  }
  const parts = v.sites.map(siteWords);
  if (v.pool) parts.push(v.pool.state === 'unknown' ? `private pool: unknown, at least ${num(v.pool.minutesAtLeast)} of ${num(v.poolLimit)} min` : `private pool: ${num(v.pool.minutesAtLeast)} of ${num(v.poolLimit)} min`);
  if (parts.length) out.push(`<div class="banner calm" data-ci-budget="count">CI this month: ${parts.join(' · ')}.</div>`);
  for (const p of v.problems || []) out.push(`<div class="banner calm" data-ci-budget="problem">CI budget: ${esc(p)}</div>`);
  return out;
}
