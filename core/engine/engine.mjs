// @ts-check
// Owns the engine adapter interface: the one shape every durable engine gives the rest of Tide, so the lifecycle (wo.mjs), the
// activities (activity.mjs, driver.mjs) and the convergence workflows never name an engine. Two engines implement it:
//   fake      core/engine/fake.mjs: in-process, files in its own folder; no install; the tests and the stand-in until Temporal runs
//   temporal  core/engine/temporal/client.mjs: Temporal (build-way 10.2, Jordan's pick 2026-10-26); needs Jordan's two installs
//             (the Temporal CLI and pinned @temporalio/* packages, core/engine/temporal/INSTALL.md); until then temporalStatus() says why not
// Called by core/engine/cli.mjs, the convergence workflows (later slice) and tests/core/engine/*.
import { spawnSync } from 'node:child_process';

/**
 * @typedef {{ status: 'done'|'waiting'|'timer'|'held'|'stopped', why: string, due?: string, state: import('./wo.mjs').WoState }} DriveResult
 * @typedef {{
 *   kind: 'fake'|'temporal',
 *   start: (wo: string, created: { goal: string, stream: string, repo?: string, alias?: string, plan?: string|null }) => Promise<DriveResult|{ status: string, why: string }>,
 *   signal: (wo: string, event: { kind: string, actor: string, data: any, at?: string, proof?: string|null }) => Promise<DriveResult|{ status: string, why: string }>,
 *   query: (wo: string) => Promise<import('./wo.mjs').WoState>,
 *   close: () => Promise<void>
 * }} EngineAdapter
 */

// The method names every adapter must have (the tests check both engines against this list).
export const ADAPTER_METHODS = ['start', 'signal', 'query', 'close'];

/** Is Temporal usable on this PC? Never installs anything; says exactly what is missing. */
export async function temporalStatus({ cli = 'temporal' } = {}) {
  const missing = [];
  const v = spawnSync(cli, ['--version'], { encoding: 'utf8', timeout: 10000, windowsHide: true });
  if (v.error || v.status !== 0) missing.push(`the Temporal CLI (\`${cli} --version\` ${v.error ? `could not start: ${v.error.message}` : `exited ${v.status}`})`);
  // Resolved from core/engine/temporal/ (where Jordan's install puts node_modules), not from here.
  for (const pkg of await (await import('./temporal/load.mjs')).missingPackages()) missing.push(`the package ${pkg}`);
  return { ok: missing.length === 0, cliVersion: v.status === 0 ? String(v.stdout).trim() : null, missing,
    why: missing.length ? `Temporal is not available: missing ${missing.join('; ')}. See core/engine/temporal/INSTALL.md (Jordan's install taps).` : 'Temporal is available' };
}

/**
 * Open an engine. kind 'fake' (default) needs nothing; kind 'temporal' refuses with the install card's reason when Temporal is missing.
 * @param {{ kind?: 'fake'|'temporal' } & Record<string, any>} o
 * @returns {Promise<EngineAdapter>}
 */
export async function openEngine(o = {}) {
  const kind = o.kind || 'fake';
  if (kind === 'fake') return (await import('./fake.mjs')).createFakeEngine(o);
  if (kind === 'temporal') {
    const st = await temporalStatus(o);
    if (!st.ok) throw new Error(st.why);
    return (await import('./temporal/client.mjs')).createTemporalEngine(o);
  }
  throw new Error(`unknown engine kind "${kind}" (fake or temporal)`);
}
