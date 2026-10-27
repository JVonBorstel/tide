// @ts-check
// Owns finding Temporal's packages: they are imported only from this folder (core/engine/temporal/), where Jordan's install tap puts
// node_modules (INSTALL.md), and only on demand, so nothing else in core/ fails to load on a PC without them.
// Called by core/engine/engine.mjs (temporalStatus), client.mjs and worker.mjs.

export const PACKAGES = ['@temporalio/client', '@temporalio/worker', '@temporalio/workflow', '@temporalio/activity'];

/** The Temporal packages that cannot be imported here, in PACKAGES order (empty when all are installed). */
export async function missingPackages() {
  const out = [];
  for (const p of PACKAGES) { try { await import(p); } catch { out.push(p); } }
  return out;
}

/** @param {'client'|'worker'} which */
export async function load(which) {
  try { return await import(`@temporalio/${which}`); } catch (err) {
    throw new Error(`@temporalio/${which} is not installed in core/engine/temporal (see INSTALL.md, Jordan's tap): ${/** @type {Error} */ (err).message}`);
  }
}
