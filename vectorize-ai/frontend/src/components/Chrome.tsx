import { useEffect, useState, type ReactNode } from 'react'
import { Link, NavLink, useNavigate } from 'react-router-dom'
import { LogOut, Menu, User as UserIcon, X } from 'lucide-react'
import { useAuth } from '../store/auth'

export function Logo({ compact = false }: { compact?: boolean }) {
  return (
    <Link to="/" className="flex items-center gap-2 text-ink" aria-label="Vectorize AI home">
      <svg viewBox="0 0 32 32" className="size-7 shrink-0" aria-hidden>
        <rect width="32" height="32" rx="8" fill="#111318" />
        <path d="M8 9h4.2l3.8 10.4L19.8 9H24l-6.1 14h-3.8z" fill="#fff" />
        <circle cx="24" cy="23" r="2.4" fill="#4f6bff" />
      </svg>
      {!compact && (
        <span className="text-[15px] font-semibold tracking-tight">
          Vectorize <span className="text-muted font-medium">AI</span>
        </span>
      )}
    </Link>
  )
}

const NAV = [
  { to: '/#features', label: 'Product' },
  { to: '/#formats', label: 'Formats' },
  { to: '/pricing', label: 'Pricing' },
  { to: '/api', label: 'API' },
]

export function Header() {
  const { user, logout } = useAuth()
  const [open, setOpen] = useState(false)
  const nav = useNavigate()
  return (
    <header className="sticky top-0 z-40 border-b border-line/80 bg-white/85 backdrop-blur supports-[backdrop-filter]:bg-white/70">
      <div className="mx-auto flex h-14 max-w-6xl items-center gap-6 px-4 sm:px-6">
        <Logo />
        <nav className="hidden items-center gap-1 md:flex">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} className="rounded-md px-2.5 py-1.5 text-sm text-muted hover:bg-subtle hover:text-ink">
              {n.label}
            </NavLink>
          ))}
        </nav>
        <div className="ml-auto hidden items-center gap-2 md:flex">
          <Link to="/pricing" className="btn-ghost btn-sm">
            Pricing
          </Link>
          {user ? (
            <>
              <Link to="/account" className="btn-secondary btn-sm">
                <UserIcon className="size-4" /> {user.name || user.email.split('@')[0]}
              </Link>
              <button className="icon-btn" title="Sign out" onClick={async () => { await logout(); nav('/') }}>
                <LogOut className="size-4" />
              </button>
            </>
          ) : (
            <Link to="/signin" className="btn-primary btn-sm">
              Sign in
            </Link>
          )}
        </div>
        <button className="icon-btn ml-auto md:hidden" aria-label="Menu" onClick={() => setOpen(!open)}>
          {open ? <X className="size-5" /> : <Menu className="size-5" />}
        </button>
      </div>
      {open && (
        <div className="border-t border-line bg-white px-4 py-3 md:hidden">
          {NAV.map((n) => (
            <Link key={n.to} to={n.to} onClick={() => setOpen(false)} className="block rounded-md px-2 py-2 text-sm text-ink-2 hover:bg-subtle">
              {n.label}
            </Link>
          ))}
          <div className="mt-2 border-t border-line pt-2">
            {user ? (
              <Link to="/account" onClick={() => setOpen(false)} className="block rounded-md px-2 py-2 text-sm">
                Account
              </Link>
            ) : (
              <Link to="/signin" onClick={() => setOpen(false)} className="btn-primary w-full">
                Sign in
              </Link>
            )}
          </div>
        </div>
      )}
    </header>
  )
}

export function Footer() {
  return (
    <footer className="border-t border-line bg-canvas">
      <div className="mx-auto grid max-w-6xl gap-8 px-4 py-10 text-sm sm:px-6 md:grid-cols-4">
        <div className="space-y-3">
          <Logo />
          <p className="max-w-xs text-muted">Raster-to-vector conversion with a shared-boundary vector graph, sub-pixel edges and real exports.</p>
        </div>
        <FooterCol title="Product" links={[['/', 'Vectorize an image'], ['/pricing', 'Pricing'], ['/account', 'Account']]} />
        <FooterCol title="Developers" links={[['/api', 'API overview'], ['/api/docs', 'Swagger UI'], ['/api/openapi.json', 'OpenAPI 3.0.3']]} />
        <FooterCol title="Formats" links={[['/#formats', 'Input: PNG JPG GIF BMP WebP TIFF'], ['/#formats', 'Output: SVG PDF EPS DXF PNG']]} />
      </div>
      <div className="border-t border-line py-4 text-center text-xs text-faint">Uploaded images are deleted automatically after the retention period.</div>
    </footer>
  )
}

function FooterCol({ title, links }: { title: string; links: [string, string][] }) {
  return (
    <div>
      <div className="panel-title mb-3">{title}</div>
      <ul className="space-y-2">
        {links.map(([to, label]) => (
          <li key={label}>
            {to.startsWith('/api/') ? (
              <a className="text-muted hover:text-ink" href={to}>
                {label}
              </a>
            ) : (
              <Link className="text-muted hover:text-ink" to={to}>
                {label}
              </Link>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}

export function Modal({ open, onClose, title, children, wide = false }: { open: boolean; onClose: () => void; title: string; children: ReactNode; wide?: boolean }) {
  useEffect(() => {
    if (!open) return
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [open, onClose])
  if (!open) return null
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-ink/30 p-0 backdrop-blur-[2px] sm:items-center sm:p-6" onMouseDown={onClose}>
      <div
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className={`max-h-[92vh] w-full overflow-auto rounded-t-2xl bg-white shadow-pop sm:rounded-2xl ${wide ? 'sm:max-w-4xl' : 'sm:max-w-lg'}`}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="sticky top-0 z-10 flex items-center justify-between border-b border-line bg-white px-5 py-3.5">
          <h2 className="text-[15px] font-semibold">{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="Close">
            <X className="size-4" />
          </button>
        </div>
        <div className="p-5">{children}</div>
      </div>
    </div>
  )
}

export function Spinner({ className = 'size-4' }: { className?: string }) {
  return (
    <svg className={`animate-spin ${className}`} viewBox="0 0 24 24" fill="none" aria-hidden>
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeOpacity="0.2" strokeWidth="3" />
      <path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
    </svg>
  )
}

export function ErrorNote({ children }: { children: ReactNode }) {
  return <div className="rounded-lg border border-danger/20 bg-danger/5 px-3 py-2 text-sm text-danger">{children}</div>
}
