// Owns reading the upgrade switches (the "upgrade" block of kitchen/kitchen.json): each new piece's switch, old for anything missing or unknown.
// Called by every upgrade lane before a new piece serves anything, and by tests/core/contracts/test-contracts.mjs. Zero dependencies.
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const SWITCH_VALUES = ['old', 'shadow', 'new'];

// The pieces come from upgrade.schema.json (one place to add a piece): dotted paths of every leaf that is a switch.
function leaves(schema, prefix = '') {
  const out = [];
  for (const [k, sub] of Object.entries(schema.properties || {})) {
    const name = prefix ? `${prefix}.${k}` : k;
    if (sub.$ref === '#/$defs/switch') out.push(name);
    else if (sub.type === 'object') out.push(...leaves(sub, name));
  }
  return out;
}
export const PIECES = leaves(JSON.parse(fs.readFileSync(path.join(here, 'upgrade.schema.json'), 'utf8')));

// The switch of one piece ("engine.adopted") in a parsed kitchen.json. Missing block, missing piece or an unknown value: old (the fallback).
export function switchOf(kitchenConfig, piece) {
  if (!PIECES.includes(piece)) throw new Error(`unknown upgrade piece "${piece}"; known: ${PIECES.join(', ')}`);
  let node = kitchenConfig && kitchenConfig.upgrade;
  for (const part of piece.split('.')) node = node && typeof node === 'object' ? node[part] : undefined;
  return SWITCH_VALUES.includes(node) ? node : 'old';
}

// Every piece's switch from one kitchen.json file. A file that will not read or parse reads as all old, with the reason.
export function readSwitches(kitchenJsonPath) {
  let cfg = null, error = null;
  try { cfg = JSON.parse(fs.readFileSync(kitchenJsonPath, 'utf8')); } catch (e) { error = e.message; }
  return { switches: Object.fromEntries(PIECES.map((p) => [p, switchOf(cfg, p)])), error };
}
