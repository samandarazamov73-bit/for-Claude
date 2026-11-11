import { useEffect, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Check } from 'lucide-react'
import { ErrorNote, Footer, Header, Spinner } from '../components/Chrome'
import { api, ApiError } from '../lib/api'
import { useAuth } from '../store/auth'

interface Plan {
  id: string
  kind: 'web' | 'api'
  name: string
  price: string
  priceCents: number
  interval: string
  description: string
  credits?: number
  perCredit?: number
  rolloverCap?: number
}

interface Plans {
  web: Plan[]
  api: Plan[]
  paymentsConfigured: boolean
  creditPrices: Record<string, number>
}

export default function Pricing() {
  const [plans, setPlans] = useState<Plans | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [err, setErr] = useState('')
  const { user, account, refresh } = useAuth()
  const nav = useNavigate()
  const [params] = useSearchParams()

  useEffect(() => {
    api<Plans>('/api/billing/plans').then(setPlans)
    refresh()
  }, [refresh])

  const subscribe = async (plan: string) => {
    setErr('')
    if (!user) return nav(`/signin?next=/pricing`)
    setBusy(plan)
    try {
      const r = await api<{ url: string }>('/api/billing/checkout', { method: 'POST', json: { plan } })
      window.location.href = r.url
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e))
      setBusy(null)
    }
  }

  return (
    <div className="min-h-screen">
      <Header />
      <main className="mx-auto max-w-6xl px-4 py-14 sm:px-6">
        <div className="mx-auto mb-10 max-w-2xl text-center">
          <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Pricing</h1>
          <p className="mt-3 text-muted">Uploading, vectorizing, editing and previewing are free. Pay to download results in the web app, or buy credits for the API.</p>
        </div>
        {params.get('checkout') === 'cancelled' && <div className="mx-auto mb-6 max-w-xl"><ErrorNote>Checkout was cancelled – you were not charged.</ErrorNote></div>}
        {err && <div className="mx-auto mb-6 max-w-xl"><ErrorNote>{err}</ErrorNote></div>}
        {plans && !plans.paymentsConfigured && (
          <div className="mx-auto mb-8 max-w-xl rounded-xl border border-line bg-canvas px-4 py-3 text-center text-sm text-muted">Online payments are not configured on this server yet — subscribing is disabled and no charge can occur.</div>
        )}

        <h2 className="panel-title mb-3">Web app</h2>
        <div className="grid gap-4 md:grid-cols-2">
          {plans?.web.map((p) => {
            const current = (account?.webPlan ?? 'web_free') === p.id
            const pro = p.id === 'web_pro'
            return (
              <div key={p.id} className={`card flex flex-col p-6 ${pro ? 'ring-1 ring-ink' : ''}`}>
                <div className="flex items-baseline justify-between">
                  <h3 className="text-lg font-semibold">{p.name}</h3>
                  {current && <span className="rounded-full bg-subtle px-2 py-0.5 text-xs text-muted">Current plan</span>}
                </div>
                <div className="mt-3 flex items-baseline gap-1">
                  <span className="text-4xl font-semibold tracking-tight">${p.price}</span>
                  <span className="text-muted">/ month</span>
                </div>
                <p className="mt-2 text-sm text-muted">{p.description}</p>
                <ul className="mt-5 flex-1 space-y-2 text-sm">
                  {(pro
                    ? ['Unlimited downloads', 'SVG, PDF, EPS, DXF and PNG', 'All editor tools', 'History of your images']
                    : ['Unlimited uploads and processing', 'Full editor and before/after preview', 'Free downloads of example images']
                  ).map((f) => (
                    <li key={f} className="flex gap-2">
                      <Check className="mt-0.5 size-4 shrink-0 text-ok" /> {f}
                    </li>
                  ))}
                </ul>
                {pro ? (
                  <button className="btn-primary mt-6 h-10" disabled={current || busy !== null || !plans.paymentsConfigured} onClick={() => subscribe(p.id)}>
                    {busy === p.id ? <Spinner /> : null} {current ? 'Subscribed' : 'Subscribe'}
                  </button>
                ) : (
                  <a href="/" className="btn-secondary mt-6 h-10">
                    Start vectorizing
                  </a>
                )}
              </div>
            )
          })}
        </div>

        <h2 className="panel-title mt-14 mb-3">API credits</h2>
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[560px] text-sm">
            <thead>
              <tr className="border-b border-line text-left text-xs text-muted">
                <th className="px-5 py-3 font-medium">Plan</th>
                <th className="px-5 py-3 font-medium">Credits / month</th>
                <th className="px-5 py-3 font-medium">Price / month</th>
                <th className="px-5 py-3 font-medium">Per image</th>
                <th className="px-5 py-3 font-medium">Rollover cap</th>
                <th className="px-5 py-3" />
              </tr>
            </thead>
            <tbody>
              {plans?.api.map((p) => (
                <tr key={p.id} className="border-b border-line last:border-0">
                  <td className="px-5 py-3 font-medium">{p.name}</td>
                  <td className="px-5 py-3 font-mono tabular-nums">{p.credits?.toLocaleString()}</td>
                  <td className="px-5 py-3 font-mono tabular-nums">${p.price}</td>
                  <td className="px-5 py-3 font-mono tabular-nums">${p.perCredit?.toFixed(2)}</td>
                  <td className="px-5 py-3 font-mono tabular-nums text-muted">{p.rolloverCap?.toLocaleString()}</td>
                  <td className="px-5 py-3 text-right">
                    <button className="btn-secondary btn-sm" disabled={busy !== null || !plans.paymentsConfigured || account?.apiPlan === p.id} onClick={() => subscribe(p.id)}>
                      {busy === p.id ? <Spinner /> : null} {account?.apiPlan === p.id ? 'Current' : 'Subscribe'}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-8 grid gap-4 md:grid-cols-2">
          <div className="card p-5">
            <h3 className="font-semibold">Credit costs</h3>
            <table className="mt-3 w-full text-sm">
              <tbody>
                {[
                  ['Production result', '1 credit'],
                  ['Preview (watermarked PNG, up to 4× size)', '0.2 credits'],
                  ['Upgrade a preview to production', '0.9 credits'],
                  ['Additional output format', '0.1 credits'],
                  ['Storage (retention) after the first free day', '0.01 credits / day'],
                  ['Test modes (heavy watermark)', 'free'],
                ].map(([a, b]) => (
                  <tr key={a} className="border-b border-line last:border-0">
                    <td className="py-2 text-muted">{a}</td>
                    <td className="py-2 text-right font-mono">{b}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="card p-5 text-sm text-muted">
            <h3 className="font-semibold text-ink">Billing terms</h3>
            <ul className="mt-3 space-y-2">
              <li>• Unused API credits roll over, up to 5× your monthly amount.</li>
              <li>• Credits are only deducted for successful requests.</li>
              <li>• Cancelling an API plan forfeits remaining credits at the end of the period.</li>
              <li>• Payments are processed by the configured payment provider; subscriptions activate only after the provider confirms payment.</li>
            </ul>
          </div>
        </div>
      </main>
      <Footer />
    </div>
  )
}
