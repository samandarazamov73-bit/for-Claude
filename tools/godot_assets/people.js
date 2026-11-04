const { chromium } = require('playwright'); const http = require('http'), fs = require('fs'), path = require('path');
const root = path.join(__dirname, 'www'); const types = { '.html': 'text/html', '.js': 'text/javascript' };
const srv = http.createServer((q, r) => { const p = path.join(root, decodeURIComponent(q.url.split('?')[0])); fs.readFile(p, (e, d) => { if (e) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' }); r.end(d); }); });
(async () => {
  await new Promise(r => srv.listen(0, r));
  const out = process.argv[2]; fs.mkdirSync(out, { recursive: true });
  const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const p = await b.newPage(); p.on('pageerror', e => console.log('pageerror', e.message)); p.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') console.log('console', m.text().slice(0, 300)); });
  await p.goto(`http://localhost:${srv.address().port}/people.html`); await p.waitForFunction(() => window.ready, null, { timeout: 60000 });
  const r = await p.evaluate(() => window.run());
  for (const [n, d] of Object.entries(r.glb)) fs.writeFileSync(path.join(out, n + '.glb'), Buffer.from(d, 'base64'));
  r.shots.forEach((d, i) => fs.writeFileSync(path.join(out, `lineup_${i}.jpg`), Buffer.from(d.split(',')[1], 'base64')));
  r.faces.forEach((d, i) => fs.writeFileSync(path.join(out, `face_${i}.jpg`), Buffer.from(d.split(',')[1], 'base64')));
  console.log('triangles', JSON.stringify(r.stats));
  for (const n of Object.keys(r.glb)) console.log(n, fs.statSync(path.join(out, n + '.glb')).size);
  await b.close(); srv.close();
})();
