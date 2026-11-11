import { useEffect, useMemo, useRef, useState } from 'react'
import { Crop } from 'lucide-react'
import { MAX_WORKING_PIXELS, formatInt } from '../lib/probe'
import { Modal } from './Chrome'

type Rect = { x: number; y: number; w: number; h: number }

interface Props {
  open: boolean
  preview: ImageBitmap | null
  width: number
  height: number
  onCancel: () => void
  onConfirm: (crop: [number, number, number, number] | null) => void
}

function defaultRect(w: number, h: number): Rect {
  const s = Math.min(1, Math.sqrt(MAX_WORKING_PIXELS / (w * h)))
  const cw = Math.floor(w * s)
  const ch = Math.floor(h * s)
  return { x: Math.floor((w - cw) / 2), y: Math.floor((h - ch) / 2), w: cw, h: ch }
}

export function PreCropDialog({ open, preview, width, height, onCancel, onConfirm }: Props) {
  const canvas = useRef<HTMLCanvasElement>(null)
  const box = useRef<HTMLDivElement>(null)
  const [rect, setRect] = useState<Rect>(() => defaultRect(width, height))
  const [disp, setDisp] = useState({ w: 640, h: 400, s: 1 })
  const drag = useRef<{ mode: string; sx: number; sy: number; r: Rect } | null>(null)

  useEffect(() => setRect(defaultRect(width, height)), [width, height])

  useEffect(() => {
    if (!open || !preview || !canvas.current || !box.current) return
    const maxW = Math.min(box.current.clientWidth || 640, 820)
    const maxH = Math.min(window.innerHeight * 0.55, 520)
    const s = Math.min(maxW / width, maxH / height)
    const w = Math.round(width * s)
    const h = Math.round(height * s)
    setDisp({ w, h, s })
    const c = canvas.current
    const dpr = window.devicePixelRatio || 1
    c.width = w * dpr
    c.height = h * dpr
    c.style.width = `${w}px`
    c.style.height = `${h}px`
    const ctx = c.getContext('2d')!
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.drawImage(preview, 0, 0, w, h)
  }, [open, preview, width, height])

  const onDown = (mode: string) => (e: React.PointerEvent) => {
    e.stopPropagation()
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    drag.current = { mode, sx: e.clientX, sy: e.clientY, r: { ...rect } }
  }
  const onMove = (e: React.PointerEvent) => {
    const d = drag.current
    if (!d) return
    const dx = (e.clientX - d.sx) / disp.s
    const dy = (e.clientY - d.sy) / disp.s
    let { x, y, w, h } = d.r
    const min = 16
    if (d.mode === 'move') {
      x = Math.min(Math.max(0, x + dx), width - w)
      y = Math.min(Math.max(0, y + dy), height - h)
    } else {
      if (d.mode.includes('w')) {
        const nx = Math.min(Math.max(0, x + dx), x + w - min)
        w += x - nx
        x = nx
      }
      if (d.mode.includes('e')) w = Math.min(Math.max(min, w + dx), width - x)
      if (d.mode.includes('n')) {
        const ny = Math.min(Math.max(0, y + dy), y + h - min)
        h += y - ny
        y = ny
      }
      if (d.mode.includes('s')) h = Math.min(Math.max(min, h + dy), height - y)
    }
    setRect({ x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h) })
  }
  const pixels = rect.w * rect.h
  const reduced = pixels > MAX_WORKING_PIXELS
  const handles = useMemo(() => ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'], [])

  return (
    <Modal open={open} onClose={onCancel} title="Pre-crop large image" wide>
      <p className="mb-4 text-sm text-muted">
        This image has <b className="text-ink">{formatInt(width * height)}</b> pixels. Vectorization works on up to {formatInt(MAX_WORKING_PIXELS)} pixels — select the part you need at full detail, or use the whole image at reduced resolution.
      </p>
      <div ref={box} className="checker relative mx-auto select-none overflow-hidden rounded-lg border border-line" style={{ width: disp.w, height: disp.h, maxWidth: '100%' }} onPointerMove={onMove} onPointerUp={() => (drag.current = null)}>
        <canvas ref={canvas} className="block" />
        <div className="pointer-events-none absolute inset-0 bg-ink/45" style={{ clipPath: `polygon(0 0, 100% 0, 100% 100%, 0 100%, 0 0, ${rect.x * disp.s}px ${rect.y * disp.s}px, ${rect.x * disp.s}px ${(rect.y + rect.h) * disp.s}px, ${(rect.x + rect.w) * disp.s}px ${(rect.y + rect.h) * disp.s}px, ${(rect.x + rect.w) * disp.s}px ${rect.y * disp.s}px, ${rect.x * disp.s}px ${rect.y * disp.s}px)` }} />
        <div className="absolute cursor-move border-2 border-white shadow-[0_0_0_1px_rgba(17,19,24,0.5)]" style={{ left: rect.x * disp.s, top: rect.y * disp.s, width: rect.w * disp.s, height: rect.h * disp.s }} onPointerDown={onDown('move')}>
          {handles.map((hd) => (
            <span
              key={hd}
              onPointerDown={onDown(hd)}
              className="absolute size-3 rounded-sm border border-ink/40 bg-white"
              style={{
                left: hd.includes('w') ? -6 : hd.includes('e') ? 'calc(100% - 6px)' : 'calc(50% - 6px)',
                top: hd.includes('n') ? -6 : hd.includes('s') ? 'calc(100% - 6px)' : 'calc(50% - 6px)',
                cursor: `${hd}-resize`,
              }}
            />
          ))}
        </div>
      </div>
      <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
        <div className="text-sm text-muted tabular-nums">
          Selection {formatInt(rect.w)} × {formatInt(rect.h)} px · {formatInt(pixels)} px {reduced && <span className="text-warn">(will be reduced)</span>}
        </div>
        <div className="flex gap-2">
          <button className="btn-secondary" onClick={() => onConfirm(null)}>
            Use whole image (reduced)
          </button>
          <button className="btn-primary" onClick={() => onConfirm([rect.x, rect.y, rect.w, rect.h])}>
            <Crop className="size-4" /> Crop & vectorize
          </button>
        </div>
      </div>
    </Modal>
  )
}
