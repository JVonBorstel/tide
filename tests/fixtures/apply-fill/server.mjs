// Test-only fixture server for tests/Test-ApplyFill.ps1. Listens on 127.0.0.1 (random port, written to <out>\port), serves the three
// fixture application forms, records the pages' live form state (POST /state/<site>, highest seq wins), every request line, any press
// marker (/marker/...) and every sent application (POST /apply/<site>, answered with a confirmation page). Exits on its own after 6 min.
//   node server.mjs <outDir>
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(process.argv[2]);
const add = (f, s) => fs.appendFileSync(path.join(out, f), s + '\n');
const seqs = {};
const html = (res, body, code = 200) => { res.writeHead(code, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); res.end(body); };
const srv = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://fixture'); const seg = u.pathname.split('/');
  const body = []; req.on('data', (c) => body.push(c));
  req.on('end', () => {
    try {
      add('requests.log', `${req.method} ${u.pathname}`);
      if (req.method === 'POST' && seg[1] === 'state') {
        const s = JSON.parse(Buffer.concat(body).toString() || '{}');
        if ((s.seq || 0) >= (seqs[seg[2]] || 0)) { seqs[seg[2]] = s.seq || 0; fs.writeFileSync(path.join(out, `state-${seg[2]}.json`), JSON.stringify(s)); }
        return html(res, 'ok');
      }
      if (seg[1] === 'marker') { add('MARKER.log', u.pathname); return html(res, 'marker'); }
      if (req.method === 'POST' && seg[1] === 'apply') {
        add('APPLIED.log', u.pathname);
        return html(res, '<!doctype html><title>Done</title><h1>Application submitted</h1><p>Thank you for applying. We have received your application.</p>');
      }
      if (['greenhouse', 'lever', 'ashby'].includes(seg[1])) return html(res, fs.readFileSync(path.join(here, `${seg[1]}.html`)));
      if (seg[1] === 'other') return html(res, '<!doctype html><title>Careers</title><form><label for="n">Name</label><input id="n"></form>');
      html(res, 'not found', 404);
    } catch { html(res, 'error', 500); }
  });
});
srv.listen(0, '127.0.0.1', () => fs.writeFileSync(path.join(out, 'port'), String(srv.address().port)));
setTimeout(() => process.exit(0), 360000);
