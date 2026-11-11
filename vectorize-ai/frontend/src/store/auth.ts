import { create } from 'zustand'
import { api } from '../lib/api'
import type { AccountSummary, User } from '../lib/types'

interface AuthState {
  user: User | null
  account: AccountSummary | null
  loaded: boolean
  refresh: () => Promise<void>
  login: (email: string, password: string) => Promise<void>
  register: (email: string, password: string, name: string) => Promise<void>
  logout: () => Promise<void>
}

export const useAuth = create<AuthState>((set, get) => ({
  user: null,
  account: null,
  loaded: false,
  async refresh() {
    try {
      const r = await api<{ user: User | null; account?: AccountSummary }>('/api/auth/me')
      set({ user: r.user, account: r.account ?? null, loaded: true })
    } catch {
      set({ loaded: true })
    }
  },
  async login(email, password) {
    await api('/api/auth/login', { method: 'POST', json: { email, password } })
    await get().refresh()
  },
  async register(email, password, name) {
    await api('/api/auth/register', { method: 'POST', json: { email, password, name } })
    await get().refresh()
  },
  async logout() {
    await api('/api/auth/logout', { method: 'POST' })
    set({ user: null, account: null })
  },
}))
