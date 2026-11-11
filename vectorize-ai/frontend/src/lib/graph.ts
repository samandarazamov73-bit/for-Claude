import type { Edits, GraphShape, PaintJSON, Seg, VectorGraphJSON } from './types'

/** Drawing command in absolute coordinates (canvas semantics). */
export type Cmd =
  | { t: 'L'; x: number; y: number }
  | { t: 'Q'; cx: number; cy: number; x: number; y: number }
  | { t: 'C'; c1x: number; c1y: number; c2x: number; c2y: number; x: number; y: number }
  | { t: 'A'; cx: number; cy: number; r: number; a0: number; a1: number; ccw: boolean }
  | { t: 'E'; cx: number; cy: number; rx: number; ry: number; rot: number; a0: number; a1: number; ccw: boolean }

export type Pt = [number, number]

interface IfaceCmds {
  start: Pt
  end: Pt
  fwd: Cmd[]
  rev: Cmd[]
}

export interface PathSink {
  moveTo(x: number, y: number): void
  lineTo(x: number, y: number): void
  quadraticCurveTo(cx: number, cy: number, x: number, y: number): void
  bezierCurveTo(a: number, b: number, c: number, d: number, x: number, y: number): void
  arc(x: number, y: number, r: number, a0: number, a1: number, ccw?: boolean): void
  ellipse(x: number, y: number, rx: number, ry: number, rot: number, a0: number, a1: number, ccw?: boolean): void
  closePath(): void
}

function ellipsePoint(cx: number, cy: number, rx: number, ry: number, rot: number, t: number): Pt {
  const co = Math.cos(rot)
  const si = Math.sin(rot)
  const x = rx * Math.cos(t)
  const y = ry * Math.sin(t)
  return [cx + co * x - si * y, cy + si * x + co * y]
}

/** Convert one interface (p0 + compact segments) to forward and reversed command lists. */
export function interfaceCmds(p0: Pt, segs: Seg[]): IfaceCmds {
  const fwd: Cmd[] = []
  const starts: Pt[] = []
  let cur: Pt = p0
  for (const s of segs) {
    starts.push(cur)
    switch (s[0]) {
      case 'L':
        fwd.push({ t: 'L', x: s[1], y: s[2] })
        cur = [s[1], s[2]]
        break
      case 'Q':
        fwd.push({ t: 'Q', cx: s[1], cy: s[2], x: s[3], y: s[4] })
        cur = [s[3], s[4]]
        break
      case 'C':
        fwd.push({ t: 'C', c1x: s[1], c1y: s[2], c2x: s[3], c2y: s[4], x: s[5], y: s[6] })
        cur = [s[5], s[6]]
        break
      case 'A': {
        const [, cx, cy, r, st, sw] = s
        fwd.push({ t: 'A', cx, cy, r, a0: st, a1: st + sw, ccw: sw < 0 })
        cur = [cx + r * Math.cos(st + sw), cy + r * Math.sin(st + sw)]
        break
      }
      case 'E': {
        const [, cx, cy, rx, ry, rot, st, sw] = s
        fwd.push({ t: 'E', cx, cy, rx, ry, rot, a0: st, a1: st + sw, ccw: sw < 0 })
        cur = ellipsePoint(cx, cy, rx, ry, rot, st + sw)
        break
      }
    }
  }
  const rev: Cmd[] = []
  for (let i = fwd.length - 1; i >= 0; i--) {
    const c = fwd[i]
    const [sx, sy] = starts[i]
    switch (c.t) {
      case 'L':
        rev.push({ t: 'L', x: sx, y: sy })
        break
      case 'Q':
        rev.push({ t: 'Q', cx: c.cx, cy: c.cy, x: sx, y: sy })
        break
      case 'C':
        rev.push({ t: 'C', c1x: c.c2x, c1y: c.c2y, c2x: c.c1x, c2y: c.c1y, x: sx, y: sy })
        break
      case 'A':
        rev.push({ ...c, a0: c.a1, a1: c.a0, ccw: !c.ccw })
        break
      case 'E':
        rev.push({ ...c, a0: c.a1, a1: c.a0, ccw: !c.ccw })
        break
    }
  }
  return { start: p0, end: cur, fwd, rev }
}

export function emit(sink: PathSink, cmds: Cmd[]): void {
  for (const c of cmds) {
    switch (c.t) {
      case 'L':
        sink.lineTo(c.x, c.y)
        break
      case 'Q':
        sink.quadraticCurveTo(c.cx, c.cy, c.x, c.y)
        break
      case 'C':
        sink.bezierCurveTo(c.c1x, c.c1y, c.c2x, c.c2y, c.x, c.y)
        break
      case 'A':
        sink.arc(c.cx, c.cy, c.r, c.a0, c.a1, c.ccw)
        break
      case 'E':
        sink.ellipse(c.cx, c.cy, c.rx, c.ry, c.rot, c.a0, c.a1, c.ccw)
        break
    }
  }
}

/** Geometry cache shared by the renderer (worker) and hit testing (main thread). */
export class GraphModel {
  readonly g: VectorGraphJSON
  readonly ifaces = new Map<number, IfaceCmds>()
  readonly shapes = new Map<number, GraphShape>()
  private loopCache = new Map<string, Path2D>()
  private shapeCache = new Map<string, Path2D>()

  constructor(g: VectorGraphJSON) {
    this.g = g
    for (const f of g.interfaces) this.ifaces.set(f.id, interfaceCmds(f.p0, f.segs))
    for (const s of g.shapes) this.shapes.set(s.id, s)
  }

  traceLoop(sink: PathSink, loop: [number, number][]): void {
    if (!loop.length) return
    const [fid, rev] = loop[0]
    const first = this.ifaces.get(fid)
    if (!first) return
    const p = rev ? first.end : first.start
    sink.moveTo(p[0], p[1])
    for (const [id, r] of loop) {
      const f = this.ifaces.get(id)
      if (f) emit(sink, r ? f.rev : f.fwd)
    }
    sink.closePath()
  }

  loopPath(shapeId: number, idx: number): Path2D {
    const key = `${shapeId}:${idx}`
    let p = this.loopCache.get(key)
    if (!p) {
      p = new Path2D()
      this.traceLoop(p, this.shapes.get(shapeId)!.loops[idx])
      this.loopCache.set(key, p)
    }
    return p
  }

  /** Outer loop plus the given hole loops (stacked rendering) or all loops (cut-out). */
  shapePath(shapeId: number, holes: number[] | 'all'): Path2D {
    const s = this.shapes.get(shapeId)!
    const list = holes === 'all' ? s.loops.map((_, i) => i).slice(1) : holes
    const key = `${shapeId}|${list.join(',')}`
    let p = this.shapeCache.get(key)
    if (!p) {
      p = new Path2D()
      p.addPath(this.loopPath(shapeId, 0))
      for (const i of list) if (i < s.loops.length) p.addPath(this.loopPath(shapeId, i))
      this.shapeCache.set(key, p)
    }
    return p
  }

  interfacePath(id: number): Path2D {
    const f = this.ifaces.get(id)!
    const p = new Path2D()
    p.moveTo(f.start[0], f.start[1])
    emit(p, f.fwd)
    return p
  }
}

// ---------------------------------------------------------------------------
// Edit state -> render state
// ---------------------------------------------------------------------------

export type RGBA = [number, number, number, number]

export function effectivePalette(g: VectorGraphJSON, e: Edits): RGBA[] {
  const pal: RGBA[] = g.palette.map((p) => [...p.rgba] as RGBA)
  for (const c of e.addedColors) pal.push([...c] as RGBA)
  for (const [k, v] of Object.entries(e.paletteOverrides)) {
    const i = Number(k)
    if (i >= 0 && i < pal.length) pal[i] = [...v] as RGBA
  }
  return pal
}

export function resolveColor(c: number, merged: Record<string, number>): number {
  const seen = new Set<number>()
  while (merged[c] !== undefined && !seen.has(c)) {
    seen.add(c)
    c = merged[c]
  }
  return c
}

export interface RenderState {
  /** CSS colour per drawable shape id; absent = not drawn */
  fill: Record<number, string>
  /** palette index per drawn shape (after edits) */
  colorOf: Record<number, number>
  /** hole loops to keep per shape when drawing stacked */
  holes: Record<number, number[]>
  /** draw order (parents before children) */
  order: number[]
  /** gradient paints of shapes whose colour was not edited */
  paints: Record<number, PaintJSON>
}

export const rgbaCss = (c: RGBA) => (c[3] >= 255 ? `rgb(${c[0]},${c[1]},${c[2]})` : `rgba(${c[0]},${c[1]},${c[2]},${(c[3] / 255).toFixed(3)})`)

export function deriveRenderState(g: VectorGraphJSON, e: Edits): RenderState {
  const pal = effectivePalette(g, e)
  const deleted = new Set(e.deletedColors)
  const hidden = new Set([...e.hiddenShapes, ...e.backgroundShapes])
  const mergeColor = new Map<number, number>()
  for (const grp of e.regionMerges) {
    const lead = grp[0]
    const leadShape = g.shapes.find((s) => s.id === lead)
    if (!leadShape) continue
    const c = e.shapeColors[lead] ?? leadShape.color
    for (const m of grp) mergeColor.set(m, c)
  }
  const fill: Record<number, string> = {}
  const colorOf: Record<number, number> = {}
  const paints: Record<number, PaintJSON> = {}
  const transparent = new Set<number>()
  for (const s of g.shapes) {
    if (s.transparent) {
      transparent.add(s.id)
      continue
    }
    let c = mergeColor.get(s.id) ?? e.shapeColors[s.id] ?? s.color
    c = resolveColor(c, e.mergedColors)
    if (c < 0 || c >= pal.length) c = s.color
    if (deleted.has(c) || hidden.has(s.id)) {
      transparent.add(s.id)
      continue
    }
    fill[s.id] = rgbaCss(pal[c])
    colorOf[s.id] = c
    const recoloured = c !== s.color || e.shapeColors[s.id] !== undefined || e.paletteOverrides[s.color] !== undefined || mergeColor.has(s.id)
    if (s.fill && !recoloured) paints[s.id] = s.fill
  }
  // stack holes: a hole may be filled by the parent only when nothing
  // transparent lies inside it (same rule as the server).
  const children = new Map<number, GraphShape[]>()
  for (const s of g.shapes) {
    const arr = children.get(s.parent) ?? []
    arr.push(s)
    children.set(s.parent, arr)
  }
  const sub = new Map<number, boolean>()
  const order = g.order.length ? g.order : g.shapes.map((s) => s.id)
  for (let i = order.length - 1; i >= 0; i--) {
    const id = order[i]
    const kids = children.get(id) ?? []
    sub.set(id, transparent.has(id) || kids.some((k) => sub.get(k.id)))
  }
  const holes: Record<number, number[]> = {}
  for (const s of g.shapes) {
    if (!(s.id in fill)) continue
    const kids = children.get(s.id) ?? []
    const keep: number[] = []
    for (let li = 1; li < s.loops.length; li++) {
      const inHole = kids.filter((k) => k.parentHole === li)
      if (!inHole.length || inHole.some((k) => sub.get(k.id))) keep.push(li)
    }
    holes[s.id] = keep
  }
  return { fill, colorOf, holes, order: order.filter((id) => id in fill), paints }
}

/** Shapes containing (x, y) in graph coordinates, topmost first. */
export function hitTest(model: GraphModel, ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D, x: number, y: number, includeTransparent = false): number | null {
  const order = model.g.order
  for (let i = order.length - 1; i >= 0; i--) {
    const s = model.shapes.get(order[i])
    if (!s || (s.transparent && !includeTransparent)) continue
    const [x0, y0, x1, y1] = s.bbox
    if (x < x0 - 1 || x > x1 + 1 || y < y0 - 1 || y > y1 + 1) continue
    if (ctx.isPointInPath(model.shapePath(s.id, 'all'), x, y, 'evenodd')) return s.id
  }
  return null
}
