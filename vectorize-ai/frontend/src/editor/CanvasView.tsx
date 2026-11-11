import { useEffect, useRef } from 'react'
import { hitTest } from '../lib/graph'
import { RenderClient } from '../render/client'
import { useEditor } from '../store/editor'

interface Props {
  source: ImageBitmap | null
  onShapeClick: (id: number | null, e: { shift: boolean }) => void
}

/** Interactive canvas: wheel/pinch zoom, drag pan, click hit-testing and the
 *  before/after divider. Rendering itself runs in a worker when possible. */
export function CanvasView({ source, onShapeClick }: Props) {
  const host = useRef<HTMLDivElement>(null)
  const client = useRef<RenderClient | null>(null)
  const hitCtx = useRef<CanvasRenderingContext2D | null>(null)
  const pointers = useRef(new Map<number, { x: number; y: number }>())
  const gesture = useRef<{ moved: boolean; sx: number; sy: number; tx: number; ty: number; pinch?: { d: number; scale: number; cx: number; cy: number } } | null>(null)
  const spaceDown = useRef(false)

  const graph = useEditor((s) => s.graph)
  const rs = useEditor((s) => s.rs)
  const view = useEditor((s) => s.view)
  const viewMode = useEditor((s) => s.viewMode)
  const split = useEditor((s) => s.split)
  const highlight = useEditor((s) => s.highlight)
  const selection = useEditor((s) => s.selection)
  const outlines = useEditor((s) => s.outlines)

  // create the canvas imperatively: transferControlToOffscreen() may only be
  // called once per element (React strict mode mounts effects twice).
  useEffect(() => {
    const el = host.current!
    const canvas = document.createElement('canvas')
    canvas.className = 'absolute inset-0 size-full touch-none'
    el.prepend(canvas)
    const c = new RenderClient(canvas)
    c.onFrame = (ms) => useEditor.getState().setFrameMs(ms)
    client.current = c
    ;(window as any).__vzRenderer = c.offscreen ? 'offscreen-worker' : 'main-thread'
    const ro = new ResizeObserver(() => {
      const r = el.getBoundingClientRect()
      c.resize(r.width, r.height, window.devicePixelRatio || 1)
      useEditor.getState().setCanvasSize(r.width, r.height)
    })
    ro.observe(el)
    const hc = document.createElement('canvas')
    hc.width = hc.height = 1
    hitCtx.current = hc.getContext('2d')
    return () => {
      ro.disconnect()
      c.dispose()
      canvas.remove()
      client.current = null
    }
  }, [])

  useEffect(() => {
    client.current?.setGraph(graph)
    if (graph && useEditor.getState().autoFit) useEditor.getState().fit()
  }, [graph])

  useEffect(() => {
    if (!source) return
    createImageBitmap(source).then((copy) => client.current?.setSource(copy))
  }, [source])

  useEffect(() => {
    client.current?.setState({ view, mode: viewMode, split, rs, highlight: [...new Set([...highlight, ...selection])], outlines })
  }, [view, viewMode, split, rs, highlight, selection, outlines])

  useEffect(() => {
    const d = (e: KeyboardEvent) => {
      if (e.code === 'Space' && !(e.target instanceof HTMLInputElement) && !(e.target instanceof HTMLTextAreaElement)) {
        spaceDown.current = e.type === 'keydown'
        if (e.type === 'keydown') e.preventDefault()
      }
    }
    window.addEventListener('keydown', d)
    window.addEventListener('keyup', d)
    return () => {
      window.removeEventListener('keydown', d)
      window.removeEventListener('keyup', d)
    }
  }, [])

  // wheel zoom (needs a non-passive listener)
  useEffect(() => {
    const el = host.current!
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const r = el.getBoundingClientRect()
      const st = useEditor.getState()
      if (!e.ctrlKey && Math.abs(e.deltaX) > Math.abs(e.deltaY) * 0.6 && e.deltaMode === 0) {
        st.setView({ ...st.view, tx: st.view.tx - e.deltaX, ty: st.view.ty - e.deltaY })
        return
      }
      const factor = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0018) * (e.deltaMode === 1 ? 16 : 1))
      st.zoomAt(factor, e.clientX - r.left, e.clientY - r.top)
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [])

  const local = (e: { clientX: number; clientY: number }) => {
    const r = host.current!.getBoundingClientRect()
    return { x: e.clientX - r.left, y: e.clientY - r.top }
  }

  const onPointerDown = (e: React.PointerEvent) => {
    if ((e.target as HTMLElement).dataset.divider) return
    host.current!.setPointerCapture(e.pointerId)
    const p = local(e)
    pointers.current.set(e.pointerId, p)
    const v = useEditor.getState().view
    if (pointers.current.size === 2) {
      const [a, b] = [...pointers.current.values()]
      gesture.current = { moved: true, sx: 0, sy: 0, tx: v.tx, ty: v.ty, pinch: { d: Math.hypot(a.x - b.x, a.y - b.y), scale: v.scale, cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2 } }
    } else {
      gesture.current = { moved: e.button === 1 || spaceDown.current, sx: p.x, sy: p.y, tx: v.tx, ty: v.ty }
    }
  }

  const onPointerMove = (e: React.PointerEvent) => {
    const g = gesture.current
    if (!g || !pointers.current.has(e.pointerId)) return
    const p = local(e)
    pointers.current.set(e.pointerId, p)
    const st = useEditor.getState()
    if (g.pinch && pointers.current.size >= 2) {
      const [a, b] = [...pointers.current.values()]
      const d = Math.hypot(a.x - b.x, a.y - b.y)
      const scale = Math.max(0.02, Math.min(64, (g.pinch.scale * d) / g.pinch.d))
      const cx = (a.x + b.x) / 2
      const cy = (a.y + b.y) / 2
      const k = scale / g.pinch.scale
      st.setView({ scale, tx: cx - (g.pinch.cx - g.tx) * k, ty: cy - (g.pinch.cy - g.ty) * k })
      return
    }
    if (!g.moved && Math.hypot(p.x - g.sx, p.y - g.sy) > 4) g.moved = true
    if (g.moved) st.setView({ ...st.view, tx: g.tx + (p.x - g.sx), ty: g.ty + (p.y - g.sy) })
  }

  const onPointerUp = (e: React.PointerEvent) => {
    const g = gesture.current
    pointers.current.delete(e.pointerId)
    if (pointers.current.size > 0) return
    gesture.current = null
    if (!g || g.moved || g.pinch) return
    const st = useEditor.getState()
    if (!st.model || !hitCtx.current) return
    const p = local(e)
    if (st.viewMode === 'split' && p.x < st.canvasSize.w * st.split) return
    const gx = (p.x - st.view.tx) / st.view.scale
    const gy = (p.y - st.view.ty) / st.view.scale
    onShapeClick(hitTest(st.model, hitCtx.current, gx, gy), { shift: e.shiftKey || e.metaKey || e.ctrlKey })
  }

  const dividerDrag = (e: React.PointerEvent) => {
    e.stopPropagation()
    const el = e.currentTarget as HTMLElement
    el.setPointerCapture(e.pointerId)
    const move = (ev: PointerEvent) => {
      const r = host.current!.getBoundingClientRect()
      useEditor.getState().setSplit((ev.clientX - r.left) / r.width)
    }
    const up = () => {
      el.removeEventListener('pointermove', move)
      el.removeEventListener('pointerup', up)
    }
    el.addEventListener('pointermove', move)
    el.addEventListener('pointerup', up)
  }

  return (
    <div
      ref={host}
      className="relative h-full w-full cursor-crosshair overflow-hidden bg-subtle"
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      data-testid="editor-canvas"
    >
      {viewMode === 'split' && (
        <>
          <div className="pointer-events-none absolute top-3 left-3 rounded bg-ink/75 px-2 py-0.5 text-[11px] font-medium text-white">Original</div>
          <div className="pointer-events-none absolute top-3 right-3 rounded bg-ink/75 px-2 py-0.5 text-[11px] font-medium text-white">Vector</div>
          <div className="absolute top-0 bottom-0 z-10 w-px bg-white shadow-[0_0_0_1px_rgba(17,19,24,0.35)]" style={{ left: `${split * 100}%` }}>
            <div
              data-divider="1"
              role="slider"
              aria-label="Before / after divider"
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={Math.round(split * 100)}
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === 'ArrowLeft') useEditor.getState().setSplit(split - 0.02)
                if (e.key === 'ArrowRight') useEditor.getState().setSplit(split + 0.02)
              }}
              onPointerDown={dividerDrag}
              className="absolute top-1/2 left-1/2 flex h-10 w-6 -translate-x-1/2 -translate-y-1/2 cursor-ew-resize items-center justify-center rounded-full border border-line bg-white shadow-pop"
            >
              <span data-divider="1" className="flex gap-0.5">
                <span data-divider="1" className="h-4 w-px bg-faint" />
                <span data-divider="1" className="h-4 w-px bg-faint" />
              </span>
            </div>
          </div>
        </>
      )}
    </div>
  )
}
