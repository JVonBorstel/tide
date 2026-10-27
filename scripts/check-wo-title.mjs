// Owns the CI gate "WO id in the PR title" (core/ship/gates.mjs woTitleGate; the pattern is in core/ship/gates.json).
// Called by the ci.yml "gates" job (--mode from GATE_WO_TITLE) and by hand: node scripts/check-wo-title.mjs --title "WO-312: ..." [--mode enforce]
// @ts-check
import { runGate, woTitleGate, prFrom } from '../core/ship/gates.mjs';

process.exitCode = runGate('WO id in the PR title', (o) => woTitleGate(prFrom(o)), process.argv.slice(2));
