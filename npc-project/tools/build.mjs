// Builds:
//   dist/npc-viewer.js  — self-contained bundle (three.js + JSZip inside), so
//                         index.html works by double-click (file://) and offline.
//   dist/artifact.html  — single-page variant that loads three.js / JSZip from
//                         public CDNs (used for the hosted preview).
import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(await readFile(path.join(root, 'node_modules/three/package.json'), 'utf8'));
const THREE_VERSION = pkg.version;
const JSZIP_VERSION = JSON.parse(await readFile(path.join(root, 'node_modules/jszip/package.json'), 'utf8')).version;
await mkdir(path.join(root, 'dist'), { recursive: true });

// 1) offline bundle
await build({
  entryPoints: [path.join(root, 'js/main.js')],
  bundle: true,
  format: 'iife',
  minify: true,
  target: 'es2020',
  outfile: path.join(root, 'dist/npc-viewer.js'),
  legalComments: 'none',
  logLevel: 'warning',
});

// 2) CDN variant for the hosted artifact
const jszipGlobal = {
  name: 'jszip-global',
  setup(b) {
    b.onResolve({ filter: /^jszip$/ }, () => ({ path: 'jszip', namespace: 'jszip-global' }));
    b.onLoad({ filter: /.*/, namespace: 'jszip-global' }, () => ({ contents: 'export default globalThis.JSZip;' }));
  },
};
const esm = await build({
  entryPoints: [path.join(root, 'js/main.js')],
  bundle: true,
  format: 'esm',
  minify: true,
  target: 'es2020',
  write: false,
  external: ['three', 'three/addons/*'],
  plugins: [jszipGlobal],
  logLevel: 'warning',
});
const moduleCode = esm.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
const html = await readFile(path.join(root, 'index.html'), 'utf8');
const css = await readFile(path.join(root, 'css/style.css'), 'utf8');
const title = html.match(/<title>[\s\S]*?<\/title>/)[0];
const fonts = [...html.matchAll(/<link[^>]+fonts\.(googleapis|gstatic)[^>]*>/g)].map((m) => m[0]).join('\n');
const app = html.slice(html.indexOf('<!--APP-START-->') + 16, html.indexOf('<!--APP-END-->'));
const importMap = {
  imports: {
    three: `https://cdn.jsdelivr.net/npm/three@${THREE_VERSION}/build/three.module.js`,
    'three/addons/': `https://cdn.jsdelivr.net/npm/three@${THREE_VERSION}/examples/jsm/`,
  },
};
const artifact = `${title}
${fonts}
<style>
${css}
</style>
${app.trim()}
<script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/${JSZIP_VERSION}/jszip.min.js"></script>
<script type="importmap">${JSON.stringify(importMap)}</script>
<script type="module">
${moduleCode}
</script>
`;
await writeFile(path.join(root, 'dist/artifact.html'), artifact);
const kb = (s) => (Buffer.byteLength(s) / 1024).toFixed(0) + ' KB';
const viewer = await readFile(path.join(root, 'dist/npc-viewer.js'), 'utf8');
console.log(`dist/npc-viewer.js ${kb(viewer)} · dist/artifact.html ${kb(artifact)} · three ${THREE_VERSION}`);
