// @ts-check
// Owns the engine's command line: read-only looks at the engine, for Jordan, a session or a script. It starts nothing and writes nothing.
//   node core/engine/cli.mjs governor [--state <folder>]          may a crew start now? (run / hold / stop, with the reason)
//   node core/engine/cli.mjs show <WO-id> [--state <folder>]      the order's stage, state and next command, from <state>\engine\events.jsonl
//   node core/engine/cli.mjs temporal                             is Temporal installed here? (names what is missing; INSTALL.md)
// --state defaults to $BRAIN_KITCHEN, else %LOCALAPPDATA%\brain-kitchen. Exit: 0 fine (governor: run), 1 governor hold/stop or Temporal
// missing, 2 bad arguments.
import path from 'node:path'; import os from 'node:os'; import { fileURLToPath } from 'node:url';
import { readUsage, decide } from './governor.mjs';
import { fileSink } from './events.mjs';
import { reduce, next } from './wo.mjs';
import { temporalStatus } from './engine.mjs';

const defaultState = () => process.env.BRAIN_KITCHEN || path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'brain-kitchen');

/** @param {string[]} argv @param {(line: string) => void} [say] */
export async function main(argv, say = console.log) {
  const i = argv.indexOf('--state'); const state = i >= 0 ? argv[i + 1] : defaultState();
  const rest = i >= 0 ? argv.filter((_, j) => j !== i && j !== i + 1) : argv;
  const [cmd, arg] = rest;
  if (!state) { say('cli: --state needs a folder'); return 2; }
  if (cmd === 'governor') {
    const u = readUsage(path.join(state, 'plan-usage.json'));
    const heavy = decide('heavy', u); const bulk = decide('bulk', u);
    say(`governor: heavy ${heavy.verdict} (${heavy.why}); bulk ${bulk.verdict} (${bulk.why})`);
    return heavy.go ? 0 : 1;
  }
  if (cmd === 'show') {
    if (!/^WO-[A-Z0-9]+(-[A-Z0-9]+)*$/.test(String(arg))) { say('cli: show needs a WO id (WO-312, WO-UPG-L2-1)'); return 2; }
    const events = fileSink(path.join(state, 'engine', 'events.jsonl')).forWo(arg);
    if (!events.length) { say(`${arg}: no engine events in ${path.join(state, 'engine', 'events.jsonl')} (not adopted yet, or the engine switch is old)`); return 0; }
    const s = reduce(events, arg); const c = next(s);
    say(`${arg}: stage ${s.stage}, ${s.state}, attempt ${s.attempt}, retries ${s.retries}${s.pr ? `, ${s.pr} at ${s.head}` : ''}`);
    say(`next: ${c.do}${'name' in c ? ` ${c.name}` : ''} (${c.why})`);
    return 0;
  }
  if (cmd === 'temporal') { const st = await temporalStatus(); say(st.ok ? `temporal: available (${st.cliVersion})` : `temporal: ${st.why}`); return st.ok ? 0 : 1; }
  say('usage: node core/engine/cli.mjs governor | show <WO-id> | temporal  [--state <folder>]');
  return 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2)).then((c) => { process.exitCode = c; });
