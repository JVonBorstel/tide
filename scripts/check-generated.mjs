// Owns the CI gate "no generated file in a PR's diff" (core/ship/gates.mjs generatedGate; the list is in core/ship/gates.json).
// Called by the ci.yml "gates" job (--mode from GATE_GENERATED, --base HEAD^1) and by hand: node scripts/check-generated.mjs --base origin/main --title "WO-1: x"
// @ts-check
import { runGate, generatedGate, diffFiles, prFrom } from '../core/ship/gates.mjs';

process.exitCode = runGate('no generated files', (o) => {
  const pr = prFrom(o);
  return generatedGate(pr ? diffFiles(o.root, o.base) : [], pr);
}, process.argv.slice(2));
