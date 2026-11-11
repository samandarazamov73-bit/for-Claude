import { useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { ErrorNote, Logo, Spinner } from '../components/Chrome'
import { Segmented } from '../editor/controls'
import { ApiError } from '../lib/api'
import { useAuth } from '../store/auth'

export default function SignIn() {
  const [params] = useSearchParams()
  const [mode, setMode] = useState<'signin' | 'register'>(params.get('mode') === 'register' ? 'register' : 'signin')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const { login, register } = useAuth()
  const nav = useNavigate()
  const next = params.get('next')?.startsWith('/') ? params.get('next')! : '/account'

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setErr('')
    try {
      if (mode === 'signin') await login(email, password)
      else await register(email, password, name)
      nav(next)
    } catch (ex) {
      setErr(ex instanceof ApiError ? ex.message : String(ex))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-canvas px-4 py-10">
      <div className="mb-6">
        <Logo />
      </div>
      <form onSubmit={submit} className="card w-full max-w-sm space-y-4 p-6">
        <Segmented value={mode} onChange={setMode} options={[{ value: 'signin', label: 'Sign in' }, { value: 'register', label: 'Create account' }]} />
        {mode === 'register' && (
          <label className="block space-y-1.5">
            <span className="label">Name</span>
            <input className="input" value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" />
          </label>
        )}
        <label className="block space-y-1.5">
          <span className="label">Email</span>
          <input className="input" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" />
        </label>
        <label className="block space-y-1.5">
          <span className="label">Password</span>
          <input className="input" type="password" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} autoComplete={mode === 'signin' ? 'current-password' : 'new-password'} />
          {mode === 'register' && <span className="text-[11px] text-faint">At least 8 characters.</span>}
        </label>
        {err && <ErrorNote>{err}</ErrorNote>}
        <button className="btn-primary h-10 w-full" disabled={busy}>
          {busy && <Spinner />} {mode === 'signin' ? 'Sign in' : 'Create account'}
        </button>
        <p className="text-center text-xs text-faint">Images you processed before signing in are added to your history.</p>
      </form>
    </div>
  )
}
