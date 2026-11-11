import type { VectorGraphJSON } from '../lib/types'
import { Renderer, type DrawState } from './renderer'

/**
 * Renders off the main thread (Web Worker + OffscreenCanvas) when the
 * browser supports it, otherwise falls back to the same renderer on the main
 * thread (coalesced with requestAnimationFrame).
 */
export class RenderClient {
  readonly offscreen: boolean
  private worker: Worker | null = null
  private local: Renderer | null = null
  private pending = false
  onFrame?: (ms: number) => void

  constructor(canvas: HTMLCanvasElement) {
    const supported = typeof OffscreenCanvas !== 'undefined' && 'transferControlToOffscreen' in canvas && typeof Path2D !== 'undefined'
    let ok = false
    if (supported) {
      try {
        const off = canvas.transferControlToOffscreen()
        this.worker = new Worker(new URL('../workers/render.worker.ts', import.meta.url), { type: 'module' })
        this.worker.onmessage = (e) => {
          if (e.data?.type === 'frame') this.onFrame?.(e.data.ms)
        }
        this.worker.postMessage({ type: 'init', canvas: off }, [off])
        ok = true
      } catch {
        this.worker?.terminate()
        this.worker = null
      }
    }
    this.offscreen = ok
    if (!ok) this.local = new Renderer(canvas)
  }

  private post(msg: object, transfer: Transferable[] = []) {
    if (this.worker) {
      this.worker.postMessage(msg, transfer)
      return
    }
    const m = msg as any
    const r = this.local!
    if (m.type === 'graph') r.setGraph(m.graph)
    else if (m.type === 'source') r.setSource(m.bitmap)
    else if (m.type === 'state') r.state = { ...r.state, ...m.state }
    else if (m.type === 'resize') r.resize(m.width, m.height, m.dpr)
    if (!this.pending) {
      this.pending = true
      requestAnimationFrame(() => {
        this.pending = false
        r.draw()
        this.onFrame?.(r.lastMs)
      })
    }
  }

  setGraph(graph: VectorGraphJSON | null) {
    this.post({ type: 'graph', graph })
  }

  setSource(bitmap: ImageBitmap | null) {
    this.post({ type: 'source', bitmap }, bitmap ? [bitmap] : [])
  }

  setState(state: Partial<DrawState>) {
    this.post({ type: 'state', state })
  }

  resize(width: number, height: number, dpr: number) {
    this.post({ type: 'resize', width, height, dpr })
  }

  dispose() {
    this.worker?.terminate()
    this.worker = null
  }
}
