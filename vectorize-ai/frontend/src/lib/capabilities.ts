import { useEffect, useState } from 'react'
import { api } from './api'

/** Server features reported by /api/health (fetched once per page load). */
export interface Capabilities {
  neuralBackground: boolean
  freeDownloads: boolean
}

const fallback: Capabilities = { neuralBackground: false, freeDownloads: false }
let pending: Promise<Capabilities> | null = null

export function loadCapabilities(): Promise<Capabilities> {
  pending ??= api<{ capabilities?: Partial<Capabilities> }>('/api/health')
    .then((h) => ({ ...fallback, ...(h.capabilities ?? {}) }))
    .catch(() => {
      pending = null
      return fallback
    })
  return pending
}

export function useCapabilities(): Capabilities | null {
  const [caps, setCaps] = useState<Capabilities | null>(null)
  useEffect(() => {
    let alive = true
    loadCapabilities().then((c) => alive && setCaps(c))
    return () => {
      alive = false
    }
  }, [])
  return caps
}
