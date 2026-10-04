// Exports every built NPC to models/<ExportName>.glb using the real viewer code
// in headless Chromium (same GLTFExporter path as the "Download" buttons).
import { chromium } from 'playwright';
import { writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(path.join(root, 'models'), { recursive: true });
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const page = await browser.newPage();
page.on('pageerror', (e) => console.error('pageerror:', e.message));
await page.goto('file://' + path.join(root, 'index.html'));
await page.waitForFunction(() => window.NPCApp, null, { timeout: 30000 });
const names = await page.evaluate(() => window.NPCApp.defs.map((d) => d.exportName));
for (let i = 0; i < names.length; i++) {
  const b64 = await page.evaluate(async (idx) => {
    const buf = await window.NPCApp.exportDef(idx, { animations: true });
    let s = '';
    const bytes = new Uint8Array(buf);
    for (let k = 0; k < bytes.length; k += 0x8000) s += String.fromCharCode(...bytes.subarray(k, k + 0x8000));
    return btoa(s);
  }, i);
  const file = path.join(root, 'models', `${names[i]}.glb`);
  await writeFile(file, Buffer.from(b64, 'base64'));
  console.log('wrote', path.relative(root, file), (Buffer.byteLength(b64, 'base64') / 1024).toFixed(0) + ' KB');
}
await browser.close();
