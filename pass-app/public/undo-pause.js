// The Board's "undo not pushed" (TD-EH-10) and "auto-merge paused" (TD-EH-11) banners. Imported by app.js (renderBanners); pure text, no
// DOM, tested in node by tests/Test-PassApp.ps1. The existing .banner and .banner calm look; nothing new to draw.
import { esc, ticket } from './scene.js';

const defaultWhen = (iso) => new Date(iso).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' });

// items: state.undoUnpushed from the server (pass-app/server.mjs undoUnpushedView, from <kitchen>\undo-unpushed\<job>.json, written by
// kitchen/undo-merge.ps1). One banner per undo that is still only on this PC, with what to do; it goes once kitchen/undo-push-check.ps1
// finds the undo on GitHub (the button runs that check now). A record that cannot be read is still a banner.
export function undoPushBanners(items, { when = defaultWhen } = {}) {
  const out = [];
  const btn = '<button class="btn" data-set="undo-push-check">Check now</button>';
  for (const u of Array.isArray(items) ? items : []) {
    if (!u) continue;
    const wo = /^J\d+$/.test(u.job || '') ? `Work order ${esc(ticket(u.job))}` : 'A work order';
    if (u.state === 'unreadable') { out.push(`<div class="banner" data-undo-push="unreadable">Undo not pushed: main on this PC may be ahead of GitHub. ${wo}'s record cannot be read, so whether its undo reached GitHub is unknown.${btn}</div>`); continue; }
    const at = u.at && !Number.isNaN(new Date(u.at).getTime()) ? ` (${esc(when(u.at))})` : '';
    const tower = u.tower ? esc(u.tower) : 'this Tower';
    const why = u.why ? esc(String(u.why)) : 'no reason was recorded';
    const cmd = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/.test(u.slug || '') ? ` (git push https://github.com/${esc(u.slug)}.git main)` : '';
    out.push(`<div class="banner" data-undo-push="${esc(u.job || '')}">Undo not pushed: main on this PC is ahead of GitHub. ${wo} was undone here${at}, but not on GitHub: ${why}. GitHub still has the change, and later merges into ${tower} hold until main is pushed. What to do: on this PC, check that main has nothing private, then push main of ${tower} to GitHub by hand${cmd}. This goes away once GitHub has the undo.${btn}</div>`);
  }
  return out;
}

// p: state.automergePause from the server (from <kitchen>\automerge-paused.json, written by kitchen/stations/verify.ps1). Shown while the
// pause lasts (its own end time against this phone's clock); nothing once it is over or when there is none.
export function autoMergePauseBanner(p, { when = defaultWhen, now = Date.now() } = {}) {
  if (!p || !p.until) return '';
  const end = new Date(p.until).getTime(); if (Number.isNaN(end) || end <= now) return '';
  const n = Math.max(1, Number(p.flaky) || 0); const suites = (Array.isArray(p.suites) ? p.suites : []).map(String).filter(Boolean);
  return `<div class="banner calm" data-automerge-pause>Auto-merge paused until ${esc(when(p.until))} after ${n} flaky ${n === 1 ? 'check' : 'checks'}${suites.length ? `: ${esc(suites.join(', '))}` : ''}. ${n === 1 ? 'It' : 'Each'} passed on main only on a retry, so AI changes wait for your sign-off until then.</div>`;
}
