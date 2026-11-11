// Copies the Swagger UI bundle into public/ so the API docs are self-hosted
// (no third-party CDN at runtime).
import { copyFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const src = dirname(require.resolve('swagger-ui-dist/package.json'))
const out = join(import.meta.dirname, '..', 'public', 'swagger')
mkdirSync(out, { recursive: true })
for (const f of ['swagger-ui-bundle.js', 'swagger-ui.css']) copyFileSync(join(src, f), join(out, f))
console.log('swagger-ui assets copied to public/swagger')
