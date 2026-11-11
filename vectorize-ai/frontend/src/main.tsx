import { StrictMode, Suspense, lazy, useEffect } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Link, Route, Routes, useLocation } from 'react-router-dom'
import './index.css'
import Landing from './pages/Landing'
import { Spinner } from './components/Chrome'
import { useAuth } from './store/auth'

// Heavier screens are code-split and loaded on demand.
const Editor = lazy(() => import('./pages/Editor'))
const Pricing = lazy(() => import('./pages/Pricing'))
const SignIn = lazy(() => import('./pages/SignIn'))
const Account = lazy(() => import('./pages/Account'))
const ApiPage = lazy(() => import('./pages/ApiPage'))

function ScrollToHash() {
  const { pathname, hash } = useLocation()
  useEffect(() => {
    if (hash) document.getElementById(hash.slice(1))?.scrollIntoView({ behavior: 'smooth' })
    else window.scrollTo(0, 0)
  }, [pathname, hash])
  return null
}

function NotFound() {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-3">
      <div className="text-5xl font-semibold">404</div>
      <p className="text-muted">This page does not exist.</p>
      <Link className="btn-primary" to="/">
        Go home
      </Link>
    </div>
  )
}

function App() {
  const refresh = useAuth((s) => s.refresh)
  useEffect(() => {
    refresh()
  }, [refresh])
  return (
    <BrowserRouter>
      <ScrollToHash />
      <Suspense fallback={<div className="flex min-h-screen items-center justify-center text-muted"><Spinner className="size-6" /></div>}>
        <Routes>
          <Route path="/" element={<Landing />} />
          <Route path="/images/:token" element={<Editor />} />
          <Route path="/images/:token/edit" element={<Editor />} />
          <Route path="/pricing" element={<Pricing />} />
          <Route path="/signin" element={<SignIn />} />
          <Route path="/account" element={<Account />} />
          <Route path="/api" element={<ApiPage />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
      </Suspense>
    </BrowserRouter>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
