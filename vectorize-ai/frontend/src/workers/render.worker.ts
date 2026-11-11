/// <reference lib="webworker" />
import { Renderer, type DrawState } from '../render/renderer'
import type { VectorGraphJSON } from '../lib/types'

type Msg =
  | { type: 'init'; canvas: OffscreenCanvas }
  | { type: 'graph'; graph: VectorGraphJSON | null }
  | { type: 'source'; bitmap: ImageBitmap | null }
  | { type: 'state'; state: Partial<DrawState> }
  | { type: 'resize'; width: number; height: number; dpr: number }

let renderer: Renderer | null = null
let scheduled = false

const raf: (cb: () => void) => void =
  typeof (self as any).requestAnimationFrame === 'function' ? (cb) => (self as any).requestAnimationFrame(cb) : (cb) => setTimeout(cb, 8)

function schedule() {
  if (scheduled || !renderer) return
  scheduled = true
  raf(() => {
    scheduled = false
    renderer?.draw()
    ;(self as unknown as Worker).postMessage({ type: 'frame', ms: renderer?.lastMs ?? 0 })
  })
}

self.onmessage = (e: MessageEvent<Msg>) => {
  const m = e.data
  try {
    if (m.type === 'init') renderer = new Renderer(m.canvas)
    else if (!renderer) return
    else if (m.type === 'graph') renderer.setGraph(m.graph)
    else if (m.type === 'source') renderer.setSource(m.bitmap)
    else if (m.type === 'state') renderer.state = { ...renderer.state, ...m.state }
    else if (m.type === 'resize') renderer.resize(m.width, m.height, m.dpr)
    schedule()
  } catch (err) {
    ;(self as unknown as Worker).postMessage({ type: 'error', message: String(err) })
  }
}
