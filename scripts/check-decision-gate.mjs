// Owns the CI gate "decision before the Board's look changes" (core/ship/gates.mjs decisionGate; the art paths are in core/ship/gates.json).
// Called by the ci.yml "gates" job (--mode from GATE_DECISION, --base HEAD^1) and by hand: node scripts/check-decision-gate.mjs --base origin/main --title "WO-1: x" --body "D-7"
// @ts-check
import { runGate, decisionGate, diffFiles, prFrom } from '../core/ship/gates.mjs';

process.exitCode = runGate('decision gate (Board look)', (o) => {
  const pr = prFrom(o);
  return decisionGate(pr ? diffFiles(o.root, o.base) : [], pr);
}, process.argv.slice(2));
