// Runs the Khronos glTF-Validator on one or more .glb files.
import { readFile } from 'node:fs/promises';
import validator from 'gltf-validator';
let failed = false;
for (const file of process.argv.slice(2)) {
  const report = await validator.validateBytes(new Uint8Array(await readFile(file)), { maxIssues: 50 });
  const { numErrors, numWarnings, numInfos, messages } = report.issues;
  const info = report.info || {};
  console.log(`${file.split('/').pop()}: errors ${numErrors}, warnings ${numWarnings}, infos ${numInfos} | ` +
    `animations ${info.animationCount}, skins ${info.skinCount ?? '-'}, materials ${info.materialCount}, ` +
    `drawCalls ${info.drawCallCount}, vertices ${info.totalVertexCount}, triangles ${info.totalTriangleCount}, maxInfluences ${info.maxInfluences}`);
  for (const m of messages.filter((m) => m.severity <= 1).slice(0, 12)) console.log(`  [${m.severity === 0 ? 'E' : 'W'}] ${m.code}: ${m.message} @ ${m.pointer || ''}`);
  if (numErrors) failed = true;
}
process.exit(failed ? 1 : 0);
