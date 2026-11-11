import { useCallback, useEffect, useState } from 'react'
import { Link, Navigate, useSearchParams } from 'react-router-dom'
import { Copy, KeyRound, Trash2 } from 'lucide-react'
import { ErrorNote, Footer, Header, Spinner } from '../components/Chrome'
import { api, ApiError } from '../lib/api'
import { useAuth } from '../store/auth'

interface Key { id: number; apiId: string; label: string; createdAt: string; lastUsedAt: string | null }
interface HistoryItem { token: string; filename: string; status: string; width: number; height: number; createdAt: string; expiresAt: string; hasResult: boolean; colors?: number; shapes?: number }
interface Usage { days: number; rows: { date: string; endpoint: string; mode: string | null; calls: number; credits: number }[]; totalCalls: number; creditsUsed: number; errors: number; webImages: number }
interface Ledger { balance: number; transactions: { id: number; delta: string; balance: string; reason: string; createdAt: string }[] }

const PLAN_NAMES: Record<string, string> = { web_free: 'Free', web_pro: 'Pro' }

export default function Account() {
  const { user, account, loaded, refresh } = useAuth()
  const [params] = useSearchParams()
  useEffect(() => {
    refresh()
  }, [refresh])
  if (loaded && !user) return <Navigate to="/signin?next=/account" replace />
  if (!user) return null
  return (
    <div className="min-h-screen bg-canvas">
      <Header />
      <main className="mx-auto max-w-6xl space-y-6 px-4 py-10 sm:px-6">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">Account</h1>
            <p className="text-sm text-muted">{user.email}</p>
          </div>
          {params.get('checkout') === 'success' && <span className="rounded-full bg-ok/10 px-3 py-1 text-sm text-ok">Payment received – your plan activates as soon as the provider confirms it.</span>}
        </div>
        <div className="grid gap-6 lg:grid-cols-3">
          <Subscription account={account} />
          <Profile />
          <Credits />
        </div>
        <History />
        <ApiKeys />
        <UsageCard />
      </main>
      <Footer />
    </div>
  )
}

function Subscription({ account }: { account: ReturnType<typeof useAuth.getState>['account'] }) {
  const [err, setErr] = useState('')
  const manage = async () => {
    try {
      const r = await api<{ url: string }>('/api/billing/portal', { method: 'POST' })
      window.location.href = r.url
    } catch (e) {
      setErr((e as Error).message)
    }
  }
  return (
    <section className="card p-5">
      <h2 className="panel-title mb-3">Subscription</h2>
      <div className="text-2xl font-semibold">{PLAN_NAMES[account?.webPlan ?? 'web_free'] ?? account?.webPlan}</div>
      <p className="mt-1 text-sm text-muted">{account?.webPlan === 'web_pro' ? 'Unlimited downloads' : 'Free plan – processing and previews only'}</p>
      <div className="mt-3 text-sm">
        API plan: <b>{account?.apiPlan ?? 'none'}</b> <span className="text-muted">({account?.apiState})</span>
      </div>
      {account?.periodEnd && <div className="text-xs text-muted">Current period ends {new Date(account.periodEnd).toLocaleDateString()}</div>}
      <div className="mt-4 flex gap-2">
        <Link to="/pricing" className="btn-primary btn-sm">
          {account?.webPlan === 'web_pro' ? 'Change plan' : 'Upgrade'}
        </Link>
        {account?.canManage && (
          <button className="btn-secondary btn-sm" onClick={manage}>
            Manage billing
          </button>
        )}
      </div>
      {err && <div className="mt-3"><ErrorNote>{err}</ErrorNote></div>}
    </section>
  )
}

function Profile() {
  const { user, refresh, logout } = useAuth()
  const [name, setName] = useState(user?.name ?? '')
  const [cur, setCur] = useState('')
  const [nw, setNw] = useState('')
  const [msg, setMsg] = useState('')
  const [err, setErr] = useState('')
  const [delPw, setDelPw] = useState('')
  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setErr('')
    setMsg('')
    try {
      await fn()
      setMsg(ok)
      refresh()
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e))
    }
  }
  return (
    <section className="card space-y-3 p-5">
      <h2 className="panel-title">Profile</h2>
      <div className="flex gap-2">
        <input className="input h-8" value={name} onChange={(e) => setName(e.target.value)} placeholder="Name" aria-label="Name" />
        <button className="btn-secondary btn-sm" onClick={() => run(() => api('/api/auth/me', { method: 'PATCH', json: { name } }), 'Saved')}>
          Save
        </button>
      </div>
      <details className="text-sm">
        <summary className="cursor-pointer text-muted">Change password</summary>
        <div className="mt-2 space-y-2">
          <input className="input h-8" type="password" placeholder="Current password" value={cur} onChange={(e) => setCur(e.target.value)} />
          <input className="input h-8" type="password" placeholder="New password (8+ characters)" value={nw} onChange={(e) => setNw(e.target.value)} />
          <button className="btn-secondary btn-sm" onClick={() => run(() => api('/api/auth/password', { method: 'POST', json: { current: cur, new: nw } }), 'Password changed')}>
            Update password
          </button>
        </div>
      </details>
      <details className="text-sm">
        <summary className="cursor-pointer text-danger">Delete account</summary>
        <div className="mt-2 space-y-2">
          <p className="text-xs text-muted">Deletes your account, images, API keys and credit history permanently.</p>
          <input className="input h-8" type="password" placeholder="Password" value={delPw} onChange={(e) => setDelPw(e.target.value)} />
          <button className="btn-sm btn border border-danger/30 text-danger hover:bg-danger/5" onClick={() => run(async () => { await api('/api/auth/delete-account', { method: 'POST', json: { password: delPw } }); await logout(); window.location.href = '/' }, 'Deleted')}>
            Delete permanently
          </button>
        </div>
      </details>
      {msg && <p className="text-xs text-ok">{msg}</p>}
      {err && <ErrorNote>{err}</ErrorNote>}
    </section>
  )
}

function Credits() {
  const [ledger, setLedger] = useState<Ledger | null>(null)
  useEffect(() => {
    api<Ledger>('/api/account/credits').then(setLedger)
  }, [])
  return (
    <section className="card p-5">
      <h2 className="panel-title mb-3">API credits</h2>
      <div className="text-2xl font-semibold tabular-nums">{ledger ? ledger.balance.toLocaleString(undefined, { maximumFractionDigits: 3 }) : '–'}</div>
      <div className="mt-3 max-h-40 overflow-auto text-xs">
        {ledger?.transactions.length ? (
          ledger.transactions.map((t) => (
            <div key={t.id} className="flex justify-between border-b border-line py-1.5 last:border-0">
              <span className="text-muted">{t.reason.replace(/_/g, ' ')}</span>
              <span className={`font-mono ${t.delta.startsWith('-') ? 'text-ink' : 'text-ok'}`}>{t.delta.startsWith('-') ? t.delta : `+${t.delta}`}</span>
            </div>
          ))
        ) : (
          <p className="text-muted">No transactions yet.</p>
        )}
      </div>
    </section>
  )
}

function History() {
  const [items, setItems] = useState<HistoryItem[] | null>(null)
  const load = useCallback(() => api<HistoryItem[]>('/api/images').then(setItems), [])
  useEffect(() => {
    load()
  }, [load])
  return (
    <section className="card p-5">
      <h2 className="panel-title mb-4">Image history</h2>
      {!items ? (
        <Spinner />
      ) : items.length === 0 ? (
        <p className="text-sm text-muted">No images yet. <Link className="text-accent" to="/">Vectorize one.</Link></p>
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          {items.map((it) => (
            <div key={it.token} className="group overflow-hidden rounded-xl border border-line bg-white">
              <Link to={`/images/${it.token}`} className="checker block aspect-[4/3]">
                {it.hasResult && <img src={`/api/images/${it.token}/thumb.png`} alt="" className="size-full object-contain p-2" loading="lazy" />}
              </Link>
              <div className="flex items-center gap-2 border-t border-line px-2.5 py-2">
                <div className="min-w-0 flex-1">
                  <div className="truncate text-xs font-medium">{it.filename}</div>
                  <div className="text-[11px] text-faint">{new Date(it.createdAt).toLocaleDateString()} · {it.status}</div>
                </div>
                <button className="icon-btn size-7" title="Delete" onClick={async () => { await api(`/api/images/${it.token}`, { method: 'DELETE' }); load() }}>
                  <Trash2 className="size-3.5" />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </section>
  )
}

function ApiKeys() {
  const [keys, setKeys] = useState<Key[]>([])
  const [label, setLabel] = useState('')
  const [fresh, setFresh] = useState<{ apiId: string; apiSecret: string } | null>(null)
  const [err, setErr] = useState('')
  const load = useCallback(() => api<Key[]>('/api/account/api-keys').then(setKeys), [])
  useEffect(() => {
    load()
  }, [load])
  const create = async () => {
    setErr('')
    try {
      const k = await api<{ apiId: string; apiSecret: string }>('/api/account/api-keys', { method: 'POST', json: { label } })
      setFresh(k)
      setLabel('')
      load()
    } catch (e) {
      setErr((e as Error).message)
    }
  }
  return (
    <section className="card p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="panel-title">API keys</h2>
        <Link to="/api" className="text-xs text-accent">API documentation</Link>
      </div>
      {fresh && (
        <div className="mb-4 rounded-xl border border-ok/30 bg-ok/5 p-4 text-sm">
          <div className="font-medium">New key created – copy the secret now, it is shown only once.</div>
          <div className="mt-2 grid gap-1 font-mono text-xs">
            <div>API Id: {fresh.apiId}</div>
            <div className="flex items-center gap-2 break-all">
              API Secret: {fresh.apiSecret}
              <button className="icon-btn size-6" title="Copy" onClick={() => navigator.clipboard?.writeText(`${fresh.apiId}:${fresh.apiSecret}`)}>
                <Copy className="size-3.5" />
              </button>
            </div>
          </div>
        </div>
      )}
      <div className="mb-4 flex gap-2">
        <input className="input h-8 max-w-xs" placeholder="Label (optional)" value={label} onChange={(e) => setLabel(e.target.value)} />
        <button className="btn-primary btn-sm" onClick={create}>
          <KeyRound className="size-3.5" /> Create key
        </button>
      </div>
      {err && <ErrorNote>{err}</ErrorNote>}
      <div className="overflow-x-auto">
        <table className="w-full min-w-[480px] text-sm">
          <tbody>
            {keys.map((k) => (
              <tr key={k.id} className="border-t border-line">
                <td className="py-2 font-mono text-xs">{k.apiId}</td>
                <td className="py-2 text-muted">{k.label || '—'}</td>
                <td className="py-2 text-xs text-muted">{k.lastUsedAt ? `used ${new Date(k.lastUsedAt).toLocaleDateString()}` : 'never used'}</td>
                <td className="py-2 text-right">
                  <button className="btn-ghost btn-sm text-danger" onClick={async () => { await api(`/api/account/api-keys/${k.id}`, { method: 'DELETE' }); load() }}>
                    Revoke
                  </button>
                </td>
              </tr>
            ))}
            {!keys.length && (
              <tr>
                <td className="py-2 text-sm text-muted">No API keys yet.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function UsageCard() {
  const [u, setU] = useState<Usage | null>(null)
  useEffect(() => {
    api<Usage>('/api/account/usage?days=30').then(setU)
  }, [])
  if (!u) return null
  const byDay = new Map<string, number>()
  u.rows.forEach((r) => byDay.set(r.date, (byDay.get(r.date) ?? 0) + r.calls))
  const days = [...byDay.entries()].sort()
  const max = Math.max(1, ...days.map((d) => d[1]))
  return (
    <section className="card p-5">
      <h2 className="panel-title mb-4">Usage · last {u.days} days</h2>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        {[
          ['API calls', u.totalCalls],
          ['Credits used', u.creditsUsed],
          ['Failed calls', u.errors],
          ['Web images', u.webImages],
        ].map(([k, v]) => (
          <div key={k as string}>
            <div className="text-xs text-muted">{k}</div>
            <div className="text-xl font-semibold tabular-nums">{v}</div>
          </div>
        ))}
      </div>
      {days.length > 0 && (
        <div className="mt-5 flex h-24 items-end gap-1" aria-label="API calls per day">
          {days.map(([d, c]) => (
            <div key={d} className="flex-1 rounded-t bg-accent/80" style={{ height: `${(c / max) * 100}%` }} title={`${d}: ${c} calls`} />
          ))}
        </div>
      )}
    </section>
  )
}
