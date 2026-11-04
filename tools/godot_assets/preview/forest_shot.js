const { chromium } = require('playwright'); const http = require('http'), fs = require('fs'), path = require('path');
const root = path.join(__dirname, 'www'); const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.jpg': 'image/jpeg' };
const srv = http.createServer((q, r) => { const p = path.join(root, decodeURIComponent(q.url.split('?')[0])); fs.readFile(p, (e, d) => { if (e) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' }); r.end(d); }); });
(async () => { await new Promise(r => srv.listen(0, r)); const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const p = await b.newPage(); p.on('pageerror', e => console.log('pageerror', e.message)); p.on('console', m => { if (m.type() === 'error') console.log('console', m.text().slice(0, 200)); });
  await p.goto(`http://localhost:${srv.address().port}/forest.html`); await p.waitForFunction(() => window.ready);
  const shots = await p.evaluate(() => window.run());
  shots.forEach((d, i) => fs.writeFileSync(`${process.argv[2]}_${i}.jpg`, Buffer.from(d.split(',')[1], 'base64'))); await b.close(); srv.close(); })();
