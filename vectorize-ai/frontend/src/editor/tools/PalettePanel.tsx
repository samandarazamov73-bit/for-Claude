import { useEffect, useMemo, useState } from 'react'
import { forceCollide, forceSimulation, forceX, forceY, type SimulationNodeDatum } from 'd3-force'
import { Eye, GitMerge, Plus, RotateCcw, Trash2 } from 'lucide-react'
import { pca2, readableInk, rgbToHex, rgbToLab, hexToRgb } from '../../lib/color'
import { effectivePalette, resolveColor } from '../../lib/graph'
import { useEditor } from '../../store/editor'
import { useEditorCtx } from '../context'
import { OptionGroup, SEGMENTATION_ATTRS, Section } from '../controls'

interface Node extends SimulationNodeDatum {
  idx: number
  r: number
  tx: number
  ty: number
  color: string
}

/** Perceptual palette map: colours placed by the first two principal
 *  components of their CIELAB coordinates, sized by area, de-overlapped
 *  with a D3 force simulation. */
function PaletteMap({ entries, selected, onSelect }: { entries: { idx: number; rgba: number[]; share: number }[]; selected: number | null; onSelect: (i: number) => void }) {
  const W = 288
  const H = 200
  const nodes = useMemo(() => {
    if (!entries.length) return []
    const labs = entries.map((e) => rgbToLab([e.rgba[0], e.rgba[1], e.rgba[2]]))
    const proj = pca2(labs, entries.map((e) => Math.max(0.02, e.share)))
    const xs = proj.map((p) => p[0])
    const ys = proj.map((p) => p[1])
    const span = (a: number[]) => Math.max(1e-6, Math.max(...a) - Math.min(...a))
    const sx = (W - 60) / span(xs)
    const sy = (H - 60) / span(ys)
    const s = Math.min(sx, sy)
    const cx = (Math.max(...xs) + Math.min(...xs)) / 2
    const cy = (Math.max(...ys) + Math.min(...ys)) / 2
    const ns: Node[] = entries.map((e, i) => ({
      idx: e.idx,
      r: 7 + 24 * Math.sqrt(e.share),
      tx: W / 2 + (proj[i][0] - cx) * s,
      ty: H / 2 + (proj[i][1] - cy) * s,
      x: W / 2 + (proj[i][0] - cx) * s,
      y: H / 2 + (proj[i][1] - cy) * s,
      color: rgbToHex(e.rgba),
    }))
    const sim = forceSimulation(ns)
      .force('x', forceX<Node>((d) => d.tx).strength(0.25))
      .force('y', forceY<Node>((d) => d.ty).strength(0.25))
      .force('collide', forceCollide<Node>((d) => d.r + 1.5).iterations(3))
      .stop()
    for (let i = 0; i < 160; i++) sim.tick()
    for (const n of ns) {
      n.x = Math.max(n.r + 2, Math.min(W - n.r - 2, n.x ?? 0))
      n.y = Math.max(n.r + 2, Math.min(H - n.r - 2, n.y ?? 0))
    }
    return ns
  }, [entries])
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="mx-auto max-h-52 w-full rounded-lg border border-line bg-canvas" role="img" aria-label="Palette map">
      {nodes.map((n) => (
        <g key={n.idx} transform={`translate(${n.x},${n.y})`} className="cursor-pointer" onClick={() => onSelect(n.idx)}>
          <circle r={n.r} fill={n.color} stroke={selected === n.idx ? '#3d5afe' : 'rgba(17,19,24,0.18)'} strokeWidth={selected === n.idx ? 2.5 : 1} />
          <title>{n.color}</title>
        </g>
      ))}
    </svg>
  )
}

export function PalettePanel() {
  const graph = useEditor((s) => s.graph)!
  const edits = useEditor((s) => s.edits)
  const rs = useEditor((s) => s.rs)
  const applyEdits = useEditor((s) => s.applyEdits)
  const setHighlight = useEditor((s) => s.setHighlight)
  const options = useEditor((s) => s.options)
  const { schema, reprocess, busy } = useEditorCtx()
  const [sel, setSel] = useState<number | null>(null)
  const [draft, setDraft] = useState(options)
  const [newColor, setNewColor] = useState('#3d5afe')
  useEffect(() => setDraft(options), [options])

  const pal = effectivePalette(graph, edits)
  const deleted = new Set(edits.deletedColors)
  const areas = useMemo(() => {
    const a = new Map<number, number>()
    for (const s of graph.shapes) {
      if (s.transparent) continue
      const c = rs?.colorOf[s.id] ?? resolveColor(s.color, edits.mergedColors)
      a.set(c, (a.get(c) ?? 0) + s.area)
    }
    return a
  }, [graph, rs, edits.mergedColors])
  const total = [...areas.values()].reduce((x, y) => x + y, 0) || 1
  const entries = pal
    .map((rgba, idx) => ({ idx, rgba, share: (areas.get(idx) ?? 0) / total }))
    .filter((e) => (e.share > 0 || idx_added(e.idx, graph.palette.length)) && !deleted.has(e.idx) && edits.mergedColors[e.idx] === undefined)
  const shapesOf = (c: number) => graph.shapes.filter((s) => !s.transparent && rs?.colorOf[s.id] === c).map((s) => s.id)
  const segDirty = Object.keys(draft).some((k) => SEGMENTATION_ATTRS.has(k) && draft[k] !== options[k])

  return (
    <div>
      <Section title={`Palette · ${entries.length} colours`}>
        <PaletteMap entries={entries.filter((e) => e.share > 0)} selected={sel} onSelect={(i) => { setSel(i); setHighlight(shapesOf(i)) }} />
        <div className="mt-3 grid max-h-64 grid-cols-1 gap-1 overflow-auto pr-1">
          {entries.map((e) => (
            <button
              key={e.idx}
              onClick={() => { setSel(e.idx); setHighlight(shapesOf(e.idx)) }}
              className={`flex items-center gap-2.5 rounded-lg border px-2 py-1.5 text-left text-[13px] ${sel === e.idx ? 'border-accent bg-accent-soft/50' : 'border-transparent hover:bg-subtle'}`}
            >
              <span className="size-6 shrink-0 rounded-md border border-ink/10" style={{ background: rgbToHex(e.rgba) }} />
              <span className="font-mono text-xs">{rgbToHex(e.rgba)}</span>
              {edits.paletteOverrides[e.idx] && <span className="rounded bg-subtle px-1 text-[10px] text-muted">edited</span>}
              <span className="ml-auto font-mono text-xs tabular-nums text-muted">{(e.share * 100).toFixed(1)}%</span>
            </button>
          ))}
        </div>
      </Section>
      {sel !== null && sel < pal.length && (
        <Section title="Selected colour">
          <div className="flex items-center gap-3">
            <label className="relative size-10 shrink-0 cursor-pointer overflow-hidden rounded-lg border border-line" style={{ background: rgbToHex(pal[sel]) }} title="Change colour">
              <input
                type="color"
                className="absolute inset-0 cursor-pointer opacity-0"
                value={rgbToHex(pal[sel])}
                onChange={(ev) => {
                  const [r, g, b] = hexToRgb(ev.target.value)
                  applyEdits((x) => ({ ...x, paletteOverrides: { ...x.paletteOverrides, [sel]: [r, g, b, pal[sel][3]] } }))
                }}
              />
              <span className="absolute inset-x-0 bottom-0 text-center text-[9px] font-medium" style={{ color: readableInk(pal[sel]) }}>edit</span>
            </label>
            <div className="min-w-0 text-[13px]">
              <div className="font-mono">{rgbToHex(pal[sel])}</div>
              <div className="text-xs text-muted">{shapesOf(sel).length} regions</div>
            </div>
          </div>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <button className="btn-secondary btn-sm" onClick={() => setHighlight(shapesOf(sel))}>
              <Eye className="size-3.5" /> Select regions
            </button>
            <button className="btn-secondary btn-sm" onClick={() => applyEdits((x) => { const o = { ...x.paletteOverrides }; delete o[sel]; return { ...x, paletteOverrides: o } })}>
              <RotateCcw className="size-3.5" /> Reset
            </button>
            <button className="btn-secondary btn-sm text-danger" onClick={() => { applyEdits((x) => ({ ...x, deletedColors: [...new Set([...x.deletedColors, sel])] })); setSel(null); setHighlight([]) }}>
              <Trash2 className="size-3.5" /> Delete
            </button>
            <select
              className="input h-8 text-[13px]"
              value=""
              aria-label="Merge into colour"
              onChange={(ev) => {
                const target = Number(ev.target.value)
                if (Number.isNaN(target)) return
                applyEdits((x) => ({ ...x, mergedColors: { ...x.mergedColors, [sel]: target } }))
                setSel(target)
              }}
            >
              <option value="">Merge into…</option>
              {entries.filter((e) => e.idx !== sel).map((e) => (
                <option key={e.idx} value={e.idx}>
                  {rgbToHex(e.rgba)}
                </option>
              ))}
            </select>
          </div>
          <p className="mt-2 flex items-center gap-1 text-[11px] text-faint"><GitMerge className="size-3" /> Merging recolours all regions; exports also join their shared borders.</p>
        </Section>
      )}
      {(edits.deletedColors.length > 0 || Object.keys(edits.mergedColors).length > 0) && (
        <Section title="Removed colours">
          <div className="flex flex-wrap gap-1.5">
            {[...edits.deletedColors, ...Object.keys(edits.mergedColors).map(Number)].map((i) => (
              <button key={i} className="flex items-center gap-1.5 rounded-md border border-line px-1.5 py-1 text-xs hover:bg-subtle" title="Restore" onClick={() => applyEdits((x) => { const m = { ...x.mergedColors }; delete m[i]; return { ...x, deletedColors: x.deletedColors.filter((d) => d !== i), mergedColors: m } })}>
                <span className="size-3.5 rounded-sm border border-ink/10" style={{ background: rgbToHex(pal[i] ?? [0, 0, 0]) }} />
                <RotateCcw className="size-3" />
              </button>
            ))}
          </div>
        </Section>
      )}
      <Section title="Custom colour">
        <div className="flex gap-2">
          <input type="color" value={newColor} onChange={(e) => setNewColor(e.target.value)} className="h-8 w-10 cursor-pointer rounded border border-line" aria-label="New colour" />
          <button className="btn-secondary btn-sm flex-1" onClick={() => { const [r, g, b] = hexToRgb(newColor); applyEdits((x) => ({ ...x, addedColors: [...x.addedColors, [r, g, b, 255]] })) }}>
            <Plus className="size-3.5" /> Add to palette
          </button>
        </div>
        <p className="mt-2 text-[11px] text-faint">Added colours can be assigned to regions in the Regions tool.</p>
      </Section>
      <Section title="Colour detection">
        <OptionGroup schema={schema} attrs={['gradients', 'max_colors', 'color_threshold', 'palette']} options={draft} onChange={(a, v) => setDraft({ ...draft, [a]: v as never })} />
        <button className="btn-primary btn-sm mt-3 w-full" disabled={!segDirty || busy} onClick={() => reprocess(draft)}>
          Re-detect colours
        </button>
        <p className="mt-2 text-[11px] text-faint">Changes the segmentation, so region edits are reset.</p>
      </Section>
    </div>
  )
}

function idx_added(idx: number, base: number) {
  return idx >= base
}
