// Headless check: opens index.html via file://, clicks through the UI,
// exports GLBs and takes screenshots.  Usage: node tools/smoke-test.mjs <outDir>
import { chromium } from 'playwright';
import { writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.resolve(process.argv[2] || path.join(root, 'test-output'));
await mkdir(out, { recursive: true });
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const errors = [];
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, acceptDownloads: true });
page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') errors.push(`${m.type()}: ${m.text()}`); });
page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
await page.goto('file://' + path.join(root, 'index.html'));
await page.waitForFunction(() => window.NPCApp && document.querySelectorAll('.anim-btn').length > 0, null, { timeout: 30000 });
await page.waitForFunction(() => /KB|MB/.test(document.getElementById('glb-size')?.textContent || ''), null, { timeout: 60000 });
await page.waitForTimeout(800);
const info = await page.evaluate(() => ({
  clips: document.querySelectorAll('.anim-btn').length,
  stats: [...document.querySelectorAll('#stats dt')].map((dt) => dt.textContent + ': ' + dt.nextElementSibling.textContent),
}));
console.log(JSON.stringify(info, null, 1));
await page.screenshot({ path: path.join(out, 'desktop-idle.png') });

// play a few clips, scrub, change speed, toggle loop
for (const clip of ['Walk', 'Talk', 'Punch_Combo']) {
  await page.click(`.anim-btn[data-clip="${clip}"]`);
  await page.waitForTimeout(450);
}
await page.click('#speed button[data-speed="0.5"]');
await page.click('#btn-pause');
await page.fill('#timeline', '0.55');
await page.dispatchEvent('#timeline', 'input');
await page.click('[data-view="left"]');
await page.waitForTimeout(800);
await page.screenshot({ path: path.join(out, 'desktop-combo-left.png') });
await page.click('#btn-play');
await page.click('#btn-stop');
await page.click('[data-view="reset"]');
await page.click('#grid-toggle');
await page.click('[data-bg="night"]');
await page.click('.anim-btn[data-clip="Wave"]');
await page.click('#mouth-chips .chip:nth-child(4)');
await page.waitForTimeout(900);
await page.screenshot({ path: path.join(out, 'desktop-wave-night.png') });

// lip-sync from text, captured mid-phrase (face close-up)
await page.click('.anim-btn[data-clip="Idle"]');
await page.click('#mouth-chips .chip:nth-child(1)');
await page.click('[data-view="front"]');
await page.waitForTimeout(700);
await page.fill('#say-input', 'Привет! Как дела?');
await page.click('#say-form button');
await page.waitForTimeout(260);
const vp = await page.locator('#viewport').boundingBox();
await page.screenshot({ path: path.join(out, 'lipsync.png'), clip: { x: vp.x + vp.width / 2 - 160, y: vp.y + 60, width: 320, height: 220 } });
console.log('say status:', await page.textContent('#say-status'));

// exports through the real buttons
for (const [btn, label] of [['#btn-glb', 'model'], ['#btn-glb-anim', 'anim']]) {
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click(btn)]);
  const file = path.join(out, dl.suggestedFilename());
  await dl.saveAs(file);
  console.log('download', label, dl.suggestedFilename());
}
await page.check('#merge-toggle');
const [dl3] = await Promise.all([page.waitForEvent('download'), page.click('#btn-glb-anim')]);
await dl3.saveAs(path.join(out, dl3.suggestedFilename()));
console.log('download merged', dl3.suggestedFilename());
console.log('status:', await page.textContent('#export-status'));

// phone layout
const phone = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
phone.on('pageerror', (e) => errors.push('phone pageerror: ' + e.message));
await phone.goto('file://' + path.join(root, 'index.html'));
await phone.waitForFunction(() => document.querySelectorAll('.anim-btn').length > 0);
await phone.waitForTimeout(1200);
const overflow = await phone.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
console.log('phone horizontal overflow px:', overflow);
await phone.screenshot({ path: path.join(out, 'phone.png'), fullPage: false });
await phone.screenshot({ path: path.join(out, 'phone-full.png'), fullPage: true });

console.log(errors.length ? 'ERRORS:\n' + errors.join('\n') : 'no console errors');
await browser.close();
