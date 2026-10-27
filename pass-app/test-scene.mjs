// Tests for the animated kitchen (pass-app/public/scene.js and sprites.js, pass-app/SCENE.md). Pure layout, markup and pixel data;
// the canvas is a recording mock (no browser, no node canvas). Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
// The checks live in five files by topic, run here in order (each reads the fixtures of the ones before): stage, world, moments, purpose, gl.
import { out } from './test-scene-stage.mjs';
import './test-scene-world.mjs';
import './test-scene-moments.mjs';
import './test-scene-purpose.mjs';
import './test-scene-gl.mjs';

console.log(JSON.stringify(out));
