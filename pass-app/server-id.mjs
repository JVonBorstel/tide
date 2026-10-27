// The server's fingerprint: one hash over server.mjs and every local module it imports (static and dynamic, followed through
// towers.mjs, work/ and core/), plus the *.schema.json files beside those modules (loaded once and cached). The server reports it in /api/health as "server"; pass-app/update.ps1 computes the same value with
// `node pass-app/server-id.mjs` to decide whether a restart is needed. Before this, only server.mjs was hashed, so a merge that changed
// only an imported module (towers.mjs, work/api.mjs) never restarted the live server.
//   node pass-app/server-id.mjs [entry]     prints the 12-hex fingerprint (entry defaults to server.mjs beside this file)
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SPEC = /(?:\bfrom\s*|\bimport\s*\(\s*)['"](\.{1,2}\/[^'"]+)['"]/g;

// every local module reachable from the entry, sorted, entry included; a specifier that names no file is skipped (it fails at load anyway)
export function serverFiles(entry) {
  const seen = new Set(), todo = [path.resolve(entry)];
  while (todo.length) {
    const f = todo.pop();
    if (seen.has(f) || !fs.existsSync(f)) continue;
    seen.add(f);
    for (const m of fs.readFileSync(f, 'utf8').matchAll(SPEC)) todo.push(path.resolve(path.dirname(f), m[1]));
  }
  // schemas a module loads at run time (core/contracts/validate.mjs reads every *.schema.json beside it and caches them)
  for (const f of [...seen]) for (const n of fs.readdirSync(path.dirname(f))) if (n.endsWith('.schema.json')) seen.add(path.join(path.dirname(f), n));
  return [...seen].sort();
}

export function serverId(entry) {
  const files = serverFiles(entry), base = path.dirname(path.resolve(entry)), h = crypto.createHash('sha256');
  for (const f of files) h.update(path.relative(base, f).split(path.sep).join('/') + '\0').update(fs.readFileSync(f)).update('\0');
  return h.digest('hex').slice(0, 12);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  console.log(serverId(process.argv[2] || path.join(path.dirname(fileURLToPath(import.meta.url)), 'server.mjs')));
}
