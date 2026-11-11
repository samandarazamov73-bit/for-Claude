import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Trash2 } from 'lucide-react'
import { useEditor } from '../../store/editor'
import type { ProcessingOptions } from '../../lib/types'
import { useEditorCtx } from '../context'
import { OptionGroup, SEGMENTATION_ATTRS, Section, Stat, Switch } from '../controls'

/** Option panel that re-runs the (cached) pipeline automatically after a
 *  short pause, so geometry changes appear in near real time. */
function LiveOptions({ title, attrs, children }: { title: string; attrs: string[]; children?: ReactNode }) {
  const options = useEditor((s) => s.options)
  const { schema, reprocess, busy } = useEditorCtx()
  const [draft, setDraft] = useState<ProcessingOptions>(options)
  const [live, setLive] = useState(true)
  const timer = useRef<number | undefined>(undefined)
  useEffect(() => setDraft(options), [options])
  const dirty = attrs.some((a) => draft[a] !== options[a])
  const needsReset = attrs.some((a) => SEGMENTATION_ATTRS.has(a) && draft[a] !== options[a])

  useEffect(() => {
    if (!live || !dirty || needsReset) return
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => reprocess(draft), 450)
    return () => window.clearTimeout(timer.current)
  }, [draft, live, dirty, needsReset, reprocess])

  return (
    <Section title={title} aside={<span className="text-[11px] text-faint">{busy ? 'updating…' : dirty ? 'pending' : 'applied'}</span>}>
      <OptionGroup schema={schema} attrs={attrs} options={draft} onChange={(a, v) => setDraft({ ...draft, [a]: v as never })} />
      {children}
      <div className="mt-3 flex items-center gap-2">
        <div className="flex-1">
          <Switch checked={live} onChange={setLive} label="Live update" />
        </div>
        <button className="btn-primary btn-sm" disabled={!dirty || busy} onClick={() => reprocess(draft)}>
          Apply
        </button>
      </div>
      {needsReset && <p className="mt-1 text-[11px] text-warn">This setting changes the segmentation; region edits will be reset when applied.</p>}
    </Section>
  )
}

export function GeometryPanel() {
  const graph = useEditor((s) => s.graph)!
  const outlines = useEditor((s) => s.outlines)
  const setOutlines = useEditor((s) => s.setOutlines)
  const selection = useEditor((s) => s.selection)
  const applyEdits = useEditor((s) => s.applyEdits)
  const setSelection = useEditor((s) => s.setSelection)
  const k = graph.stats.segment_kinds ?? {}
  return (
    <div>
      <LiveOptions title="Curves" attrs={['fit_tolerance', 'subpixel', 'curves_cubic', 'curves_quadratic', 'curves_arcs']} />
      <LiveOptions title="Cleanup" attrs={['min_area_px', 'denoise']} />
      <Section title="Objects">
        <Switch checked={outlines} onChange={setOutlines} label="Show edges (wireframe)" />
        <button className="btn-secondary btn-sm mt-2 w-full text-danger" disabled={!selection.length} onClick={() => { applyEdits((x) => ({ ...x, hiddenShapes: [...new Set([...x.hiddenShapes, ...selection])] })); setSelection([]) }}>
          <Trash2 className="size-3.5" /> Delete selected objects
        </button>
      </Section>
      <Section title="Statistics">
        <Stat label="Shapes" value={graph.stats.shapes} />
        <Stat label="Shared edges (interfaces)" value={graph.stats.interfaces} />
        <Stat label="Junctions" value={graph.stats.nodes} />
        <Stat label="Segments" value={graph.stats.segments} />
        <Stat label="Lines / arcs" value={`${k.L ?? 0} / ${(k.A ?? 0) + (k.E ?? 0)}`} />
        <Stat label="Béziers (cubic / quad)" value={`${k.C ?? 0} / ${k.Q ?? 0}`} />
        <Stat label="Tolerance used" value={`${graph.stats.fit_tolerance} px`} />
      </Section>
    </div>
  )
}

export function CornersPanel() {
  const graph = useEditor((s) => s.graph)!
  const lines = graph.stats.segment_kinds?.L ?? 0
  return (
    <div>
      <LiveOptions title="Corners" attrs={['corners_mode', 'corners_strength']}>
        <p className="mt-2 text-[11px] leading-snug text-faint">
          <b>Auto</b> rebuilds a corner as an exact vertex when the raster rounding matches a sharp corner; <b>Sharp</b> forces every detected corner; <b>Rounded</b> keeps all rounding. Strength widens the sharp/rounded threshold.
        </p>
      </LiveOptions>
      <Section title="Result">
        <Stat label="Straight segments" value={lines} />
        <Stat label="Segments total" value={graph.stats.segments} />
      </Section>
    </div>
  )
}

export function SymmetryPanel() {
  const graph = useEditor((s) => s.graph)!
  const setHighlight = useEditor((s) => s.setHighlight)
  const sym = useMemo(() => graph.shapes.filter((s) => s.symmetry), [graph])
  const rep = useMemo(() => graph.shapes.filter((s) => s.repeat !== undefined), [graph])
  return (
    <div>
      <LiveOptions title="Symmetry" attrs={['symmetry_mirror', 'symmetry_rotation', 'symmetry_repeats', 'symmetry_tolerance']} />
      <Section title="Detected">
        <Stat label="Symmetric shapes" value={sym.length} />
        <Stat label="Horizontal / vertical axes" value={`${sym.filter((s) => s.symmetry!.mirror.some((m) => m.axis === 'horizontal')).length} / ${sym.filter((s) => s.symmetry!.mirror.some((m) => m.axis === 'vertical')).length}`} />
        <Stat label="Rotational" value={sym.filter((s) => s.symmetry!.rotation > 1).length} />
        <Stat label="Repeated shapes" value={rep.length} />
        <div className="mt-2 grid grid-cols-2 gap-2">
          <button className="btn-secondary btn-sm" disabled={!sym.length} onClick={() => setHighlight(sym.map((s) => s.id))}>
            Show symmetric
          </button>
          <button className="btn-secondary btn-sm" disabled={!rep.length} onClick={() => setHighlight(rep.map((s) => s.id))}>
            Show repeats
          </button>
        </div>
      </Section>
    </div>
  )
}

const SHAPE_LABEL: Record<string, string> = { circle: 'Circles', ellipse: 'Ellipses', rectangle: 'Rectangles', rounded_rectangle: 'Rounded rectangles', triangle: 'Triangles', quadrilateral: 'Quadrilaterals', star: 'Stars' }

export function ShapesPanel() {
  const graph = useEditor((s) => s.graph)!
  const setHighlight = useEditor((s) => s.setHighlight)
  const counts = useMemo(() => {
    const m = new Map<string, number[]>()
    for (const s of graph.shapes) if (s.primitive) m.set(s.primitive.type, [...(m.get(s.primitive.type) ?? []), s.id])
    return m
  }, [graph])
  return (
    <div>
      <LiveOptions title="Shape recognition" attrs={['shapes_enabled', 'shapes_circle', 'shapes_ellipse', 'shapes_rectangle', 'shapes_rounded_rectangle', 'shapes_triangle', 'shapes_quadrilateral', 'shapes_star']} />
      <Section title="Recognised">
        {counts.size === 0 && <p className="text-[13px] text-muted">No whole parametric shapes were found.</p>}
        {[...counts.entries()].map(([t, ids]) => (
          <button key={t} className="flex w-full items-center justify-between rounded-md px-1 py-1 text-[13px] hover:bg-subtle" onClick={() => setHighlight(ids)}>
            <span>{SHAPE_LABEL[t] ?? t}</span>
            <span className="font-mono text-xs text-muted">{ids.length}</span>
          </button>
        ))}
      </Section>
    </div>
  )
}
