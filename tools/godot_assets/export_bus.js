const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const root = path.join(__dirname, 'www');
const types = { '.html': 'text/html', '.js': 'text/javascript' };
const srv = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(req.url.split('?')[0]));
  fs.readFile(p, (e, d) => { if (e) { res.writeHead(404); res.end(); return; } res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' }); res.end(d); });
});
(async () => {
  await new Promise(r => srv.listen(0, r));
  const out = process.argv[2];
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, acceptDownloads: true });
  page.on('pageerror', e => console.log('pageerror:', e.message));
  page.on('console', m => { if (m.type() === 'error') console.log('console:', m.text().slice(0, 300)); });
  const t0 = Date.now();
  await page.goto(`http://localhost:${srv.address().port}/bus.html`);
  await page.waitForFunction(() => window.__bus && window.__bus.ready, null, { timeout: 600000, polling: 1000 });
  console.log('built in', ((Date.now() - t0) / 1000).toFixed(1), 's');
  await page.screenshot({ path: out.replace('.glb', '_page.png') });
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 600000 }), page.click('#btn-export-glb')]);
  await dl.saveAs(out);
  console.log('saved', out, fs.statSync(out).size, 'bytes in', ((Date.now() - t0) / 1000).toFixed(1), 's');
  await browser.close(); srv.close();
})();
