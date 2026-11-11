import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { ExternalLink } from 'lucide-react'
import { Footer, Header } from '../components/Chrome'
import { api } from '../lib/api'

interface ErrorRow { code: number; status: number; key: string; description: string }

const CURL = `curl https://YOUR_HOST/api/v1/vectorize \\
  -u 'API_ID:API_SECRET' \\
  -F image=@logo.png \\
  -F output.file_format=svg \\
  -F processing.max_colors=8 \\
  -o result.svg`

const PY = `import requests

r = requests.post(
    "https://YOUR_HOST/api/v1/vectorize",
    auth=("API_ID", "API_SECRET"),
    files={"image": open("logo.png", "rb")},
    data={"mode": "production", "output.file_format": "pdf", "policy.retention_days": 1},
)
r.raise_for_status()
open("result.pdf", "wb").write(r.content)
print(r.headers["X-Credits-Charged"], r.headers.get("X-Image-Token"))`

export default function ApiPage() {
  const [errors, setErrors] = useState<ErrorRow[]>([])
  useEffect(() => {
    api<{ errors: ErrorRow[] }>('/api/meta/options').then((o) => setErrors(o.errors))
  }, [])
  return (
    <div className="min-h-screen">
      <Header />
      <main className="mx-auto max-w-5xl px-4 py-12 sm:px-6">
        <h1 className="text-3xl font-semibold tracking-tight">REST API</h1>
        <p className="mt-2 max-w-2xl text-muted">The same engine as the web app. Send an image as <code className="font-mono text-sm">multipart/form-data</code> and receive the vector file in the response body.</p>
        <div className="mt-6 flex flex-wrap gap-2">
          <a href="/api/docs" className="btn-primary">
            Swagger UI <ExternalLink className="size-4" />
          </a>
          <a href="/api/openapi.json" className="btn-secondary">
            OpenAPI 3.0.3 JSON
          </a>
          <Link to="/account" className="btn-secondary">
            Get an API key
          </Link>
        </div>

        <div className="mt-10 grid gap-6 lg:grid-cols-2">
          <div>
            <h2 className="panel-title mb-2">Quick start (curl)</h2>
            <pre className="overflow-x-auto rounded-xl bg-ink p-4 font-mono text-[12.5px] leading-relaxed text-white/90">{CURL}</pre>
          </div>
          <div>
            <h2 className="panel-title mb-2">Python</h2>
            <pre className="overflow-x-auto rounded-xl bg-ink p-4 font-mono text-[12.5px] leading-relaxed text-white/90">{PY}</pre>
          </div>
        </div>

        <div className="mt-10 grid gap-4 md:grid-cols-2">
          {[
            ['POST /api/v1/vectorize', 'Input via image (file), image.url, image.base64 (≤1 MB) or image.token. Modes: production (1 credit), preview (0.2), test and test_preview (free, watermarked). All processing.* and output.* options are accepted.'],
            ['POST /api/v1/download', 'Download a retained result in another format (0.1 credits) or upgrade a preview with its receipt (0.9 credits).'],
            ['POST /api/v1/delete', 'Delete a retained image immediately.'],
            ['GET /api/v1/account', 'Subscription plan, state and credit balance.'],
          ].map(([t, d]) => (
            <div key={t} className="card p-4">
              <div className="font-mono text-sm font-medium">{t}</div>
              <p className="mt-1.5 text-sm text-muted">{d}</p>
            </div>
          ))}
        </div>

        <div className="mt-10 card p-5 text-sm text-muted">
          <h2 className="mb-2 font-semibold text-ink">Authentication, headers and limits</h2>
          <ul className="space-y-1.5">
            <li>• HTTP Basic: API Id as user name, API Secret as password.</li>
            <li>• Response headers: <code className="font-mono">X-Credits-Charged</code>, <code className="font-mono">X-Credits-Calculated</code>, and with <code className="font-mono">policy.retention_days &gt; 0</code> also <code className="font-mono">X-Image-Token</code> and <code className="font-mono">X-Receipt</code>.</li>
            <li>• Files up to 30 MiB / 33,554,432 px. Use a client timeout of at least 180 s.</li>
            <li>• On HTTP 429 wait for <code className="font-mono">Retry-After</code>. For batch jobs start with 5 parallel requests and add one every 5 minutes.</li>
          </ul>
        </div>

        <h2 className="panel-title mt-10 mb-3">Error codes</h2>
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[560px] text-sm">
            <thead>
              <tr className="border-b border-line text-left text-xs text-muted">
                <th className="px-4 py-2.5 font-medium">Code</th>
                <th className="px-4 py-2.5 font-medium">HTTP</th>
                <th className="px-4 py-2.5 font-medium">Meaning</th>
              </tr>
            </thead>
            <tbody>
              {errors.map((e) => (
                <tr key={`${e.code}-${e.key}`} className="border-b border-line last:border-0">
                  <td className="px-4 py-2 font-mono">{e.code}</td>
                  <td className="px-4 py-2 font-mono text-muted">{e.status}</td>
                  <td className="px-4 py-2 text-muted">{e.description}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </main>
      <Footer />
    </div>
  )
}
