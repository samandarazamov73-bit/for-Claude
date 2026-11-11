import { GraphModel, type RenderState } from '../lib/graph'
import type { PaintJSON, VectorGraphJSON } from '../lib/types'

export type Ctx2D = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D

export interface View {
  scale: number // screen px per graph px
  tx: number // screen offset (css px)
  ty: number
}

export interface DrawState {
  view: View
  mode: 'vector' | 'source' | 'split'
  split: number // 0..1 of the canvas width (split mode)
  rs: RenderState | null
  highlight: number[]
  highlightColor: string
  outlines: boolean
}

/** Pure drawing routine; no DOM access so it runs in a worker as well. */
export class Renderer {
  private ctx: Ctx2D
  private model: GraphModel | null = null
  private source: ImageBitmap | null = null
  private pattern: CanvasPattern | null = null
  private gradients = new Map<number, CanvasGradient>()
  width = 1
  height = 1
  dpr = 1
  state: DrawState = { view: { scale: 1, tx: 0, ty: 0 }, mode: 'vector', split: 0.5, rs: null, highlight: [], highlightColor: '#3d5afe', outlines: false }
  lastMs = 0

  constructor(private canvas: OffscreenCanvas | HTMLCanvasElement) {
    const ctx = canvas.getContext('2d', { alpha: false }) as Ctx2D | null
    if (!ctx) throw new Error('2D canvas not supported')
    this.ctx = ctx
  }

  setGraph(g: VectorGraphJSON | null) {
    this.model = g ? new GraphModel(g) : null
    this.gradients.clear()
  }

  private gradientFor(id: number, p: PaintJSON): CanvasGradient {
    let g = this.gradients.get(id)
    if (!g) {
      g = p.type === 'linear' ? this.ctx.createLinearGradient(p.x1, p.y1, p.x2, p.y2) : this.ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
      for (const s of p.stops) g.addColorStop(Math.min(1, Math.max(0, s[0])), `rgba(${s[1]},${s[2]},${s[3]},${(s[4] ?? 255) / 255})`)
      this.gradients.set(id, g)
    }
    return g
  }

  /** Fill a shape with its gradient. Radial gradients are defined on the
   *  unit circle and mapped by an affine matrix: clip to the shape, apply the
   *  matrix and cover the clip area. */
  private fillPaint(id: number, path: Path2D, p: PaintJSON) {
    const ctx = this.ctx
    if (p.type === 'linear') {
      ctx.fillStyle = this.gradientFor(id, p)
      ctx.fill(path, 'evenodd')
      return
    }
    const [a, b, c, d, e, f] = p.m
    const det = a * d - b * c
    if (Math.abs(det) < 1e-12) return
    const bb = this.model!.shapes.get(id)!.bbox
    const inv = (x: number, y: number): [number, number] => [(d * (x - e) - c * (y - f)) / det, (-b * (x - e) + a * (y - f)) / det]
    const pts = [inv(bb[0], bb[1]), inv(bb[2], bb[1]), inv(bb[0], bb[3]), inv(bb[2], bb[3])]
    const xs = pts.map((q) => q[0])
    const ys = pts.map((q) => q[1])
    ctx.save()
    ctx.clip(path, 'evenodd')
    ctx.transform(a, b, c, d, e, f)
    ctx.fillStyle = this.gradientFor(id, p)
    const x0 = Math.min(...xs) - 0.05, y0 = Math.min(...ys) - 0.05
    ctx.fillRect(x0, y0, Math.max(...xs) - x0 + 0.1, Math.max(...ys) - y0 + 0.1)
    ctx.restore()
  }

  setSource(b: ImageBitmap | null) {
    this.source?.close?.()
    this.source = b
  }

  resize(w: number, h: number, dpr: number) {
    this.width = Math.max(1, w)
    this.height = Math.max(1, h)
    this.dpr = dpr
    this.canvas.width = Math.round(this.width * dpr)
    this.canvas.height = Math.round(this.height * dpr)
  }

  private checker(): CanvasPattern | null {
    if (this.pattern) return this.pattern
    const size = 16
    const c = typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(size, size) : Object.assign(document.createElement('canvas'), { width: size, height: size })
    const x = c.getContext('2d') as Ctx2D
    x.fillStyle = '#ffffff'
    x.fillRect(0, 0, size, size)
    x.fillStyle = '#e9eaee'
    x.fillRect(0, 0, size / 2, size / 2)
    x.fillRect(size / 2, size / 2, size / 2, size / 2)
    this.pattern = this.ctx.createPattern(c as unknown as CanvasImageSource, 'repeat')
    return this.pattern
  }

  draw() {
    const t0 = performance.now()
    const { ctx, dpr } = this
    const { view, mode, split, rs } = this.state
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.fillStyle = '#f1f2f5'
    ctx.fillRect(0, 0, this.width, this.height)
    const g = this.model?.g
    const gw = g?.width ?? this.source?.width ?? 0
    const gh = g?.height ?? this.source?.height ?? 0
    if (!gw || !gh) return
    // image frame with transparency checkerboard
    const fx = view.tx, fy = view.ty, fw = gw * view.scale, fh = gh * view.scale
    ctx.save()
    ctx.shadowColor = 'rgba(17,19,24,0.12)'
    ctx.shadowBlur = 12
    ctx.shadowOffsetY = 2
    ctx.fillStyle = '#ffffff'
    ctx.fillRect(fx, fy, fw, fh)
    ctx.restore()
    const pat = this.checker()
    if (pat) {
      ctx.fillStyle = pat
      ctx.fillRect(fx, fy, fw, fh)
    }
    const splitX = this.width * split

    if (mode === 'source' || mode === 'split') {
      ctx.save()
      if (mode === 'split') {
        ctx.beginPath()
        ctx.rect(0, 0, splitX, this.height)
        ctx.clip()
      }
      if (this.source) {
        ctx.imageSmoothingEnabled = view.scale < 2
        ctx.setTransform(dpr * view.scale, 0, 0, dpr * view.scale, dpr * view.tx, dpr * view.ty)
        ctx.drawImage(this.source, 0, 0, gw, gh)
      }
      ctx.restore()
    }
    if ((mode === 'vector' || mode === 'split') && this.model && rs) {
      ctx.save()
      if (mode === 'split') {
        ctx.beginPath()
        ctx.rect(splitX, 0, this.width - splitX, this.height)
        ctx.clip()
      }
      ctx.setTransform(dpr * view.scale, 0, 0, dpr * view.scale, dpr * view.tx, dpr * view.ty)
      ctx.beginPath()
      ctx.rect(0, 0, gw, gh)
      ctx.clip()
      const m = this.model
      for (const id of rs.order) {
        const fill = rs.fill[id]
        if (!fill) continue
        const path = m.shapePath(id, rs.holes[id] ?? [])
        const paint = rs.paints?.[id]
        if (paint) this.fillPaint(id, path, paint)
        else {
          ctx.fillStyle = fill
          ctx.fill(path, 'evenodd')
        }
      }
      if (this.state.outlines) {
        ctx.lineWidth = 1 / view.scale
        ctx.strokeStyle = 'rgba(17,19,24,0.55)'
        for (const f of m.g.interfaces) ctx.stroke(m.interfacePath(f.id))
      }
      if (this.state.highlight.length) {
        ctx.fillStyle = this.state.highlightColor + '33'
        ctx.strokeStyle = this.state.highlightColor
        ctx.lineWidth = 2 / view.scale
        ctx.setLineDash([6 / view.scale, 4 / view.scale])
        for (const id of this.state.highlight) {
          if (!m.shapes.has(id)) continue
          const p = m.shapePath(id, 'all')
          ctx.fill(p, 'evenodd')
          ctx.stroke(p)
        }
        ctx.setLineDash([])
      }
      ctx.restore()
    }
    this.lastMs = performance.now() - t0
  }
}
