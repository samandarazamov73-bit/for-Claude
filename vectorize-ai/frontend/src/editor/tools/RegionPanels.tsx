import { useState } from 'react'
import { Combine, Eraser, Paintbrush, RotateCcw, Trash2, WandSparkles } from 'lucide-react'
import { api } from '../../lib/api'
import { rgbToHex } from '../../lib/color'
import { effectivePalette } from '../../lib/graph'
import { useEditor } from '../../store/editor'
import { ErrorNote, Spinner } from '../../components/Chrome'
import { useEditorCtx } from '../context'
import { Section, Segmented, Stat, Switch } from '../controls'

export function BackgroundPanel() {
  const { token } = useEditorCtx()
  const edits = useEditor((s) => s.edits)
  const applyEdits = useEditor((s) => s.applyEdits)
  const setHighlight = useEditor((s) => s.setHighlight)
  const [method, setMethod] = useState<'auto' | 'color' | 'grabcut'>('auto')
  const [enclosed, setEnclosed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [info, setInfo] = useState('')

  const detect = async () => {
    setBusy(true)
    setErr('')
    try {
      const r = await api<{ method: string; shapes: number[]; border_share: number | null }>(`/api/images/${token}/background`, { method: 'POST', json: { method, includeEnclosed: enclosed } })
      applyEdits((x) => ({ ...x, backgroundShapes: r.shapes }))
      setInfo(r.shapes.length ? `${r.shapes.length} region${r.shapes.length > 1 ? 's' : ''} removed (${r.method === 'grabcut' ? 'GrabCut segmentation' : 'border colour analysis'}).` : 'No opaque background found – it may already be transparent.')
    } catch (e) {
      setErr(String((e as Error).message))
    } finally {
      setBusy(false)
    }
  }
  return (
    <div>
      <Section title="Automatic removal">
        <div className="space-y-3">
          <Segmented value={method} onChange={setMethod} size="sm" options={[{ value: 'auto', label: 'Auto' }, { value: 'color', label: 'Colour' }, { value: 'grabcut', label: 'Foreground' }]} />
          <Switch checked={enclosed} onChange={setEnclosed} label="Also remove enclosed areas of the background colour (e.g. letter counters)" />
          <button className="btn-primary btn-sm w-full" onClick={detect} disabled={busy}>
            {busy ? <Spinner /> : <WandSparkles className="size-3.5" />} Remove background
          </button>
          {info && <p className="text-xs text-muted">{info}</p>}
          {err && <ErrorNote>{err}</ErrorNote>}
        </div>
      </Section>
      <Section title="Manual">
        <p className="text-[13px] text-muted">Click regions on the canvas to add or remove them from the background. Removed areas become transparent (checkerboard) in the preview and in every export.</p>
        <Stat label="Background regions" value={edits.backgroundShapes.length} />
        <div className="mt-2 grid grid-cols-2 gap-2">
          <button className="btn-secondary btn-sm" onClick={() => setHighlight(edits.backgroundShapes)} disabled={!edits.backgroundShapes.length}>
            Show outlines
          </button>
          <button className="btn-secondary btn-sm" onClick={() => { applyEdits((x) => ({ ...x, backgroundShapes: [] })); setHighlight([]); setInfo('') }} disabled={!edits.backgroundShapes.length}>
            <RotateCcw className="size-3.5" /> Restore
          </button>
        </div>
      </Section>
    </div>
  )
}

export function RegionsPanel() {
  const graph = useEditor((s) => s.graph)!
  const edits = useEditor((s) => s.edits)
  const rs = useEditor((s) => s.rs)
  const selection = useEditor((s) => s.selection)
  const setSelection = useEditor((s) => s.setSelection)
  const applyEdits = useEditor((s) => s.applyEdits)
  const pal = effectivePalette(graph, edits)
  const sel = selection.filter((id) => graph.shapes.some((s) => s.id === id))
  const area = sel.reduce((a, id) => a + (graph.shapes.find((s) => s.id === id)?.area ?? 0), 0)
  const selColors = [...new Set(sel.map((id) => rs?.colorOf[id]).filter((c) => c !== undefined))] as number[]
  const usable = pal.map((c, i) => ({ c, i })).filter(({ i }) => !edits.deletedColors.includes(i) && edits.mergedColors[i] === undefined)

  return (
    <div>
      <Section title="Selection">
        {sel.length === 0 ? (
          <p className="text-[13px] text-muted">Click a region on the canvas. Hold <span className="kbd">Shift</span> to select several.</p>
        ) : (
          <>
            <Stat label="Selected regions" value={sel.length} />
            <Stat label="Area" value={`${Math.round(area).toLocaleString()} px²`} />
            <div className="mt-2 flex flex-wrap gap-1">
              {selColors.map((c) => (
                <span key={c} className="size-5 rounded border border-ink/10" style={{ background: rgbToHex(pal[c]) }} />
              ))}
            </div>
          </>
        )}
      </Section>
      <Section title="Recolour">
        <div className="grid grid-cols-8 gap-1.5">
          {usable.map(({ c, i }) => (
            <button
              key={i}
              disabled={!sel.length}
              title={rgbToHex(c)}
              className="aspect-square rounded-md border border-ink/10 transition hover:scale-110 disabled:opacity-40 disabled:hover:scale-100"
              style={{ background: rgbToHex(c) }}
              onClick={() => applyEdits((x) => ({ ...x, shapeColors: { ...x.shapeColors, ...Object.fromEntries(sel.map((id) => [id, i])) } }))}
            />
          ))}
        </div>
        <p className="mt-2 flex items-center gap-1 text-[11px] text-faint"><Paintbrush className="size-3" /> Add custom colours in the Palette tool.</p>
      </Section>
      <Section title="Actions">
        <div className="grid grid-cols-2 gap-2">
          <button className="btn-secondary btn-sm" disabled={sel.length < 2} onClick={() => applyEdits((x) => ({ ...x, regionMerges: [...x.regionMerges, sel] }))}>
            <Combine className="size-3.5" /> Merge
          </button>
          <button className="btn-secondary btn-sm text-danger" disabled={!sel.length} onClick={() => { applyEdits((x) => ({ ...x, hiddenShapes: [...new Set([...x.hiddenShapes, ...sel])] })); setSelection([]) }}>
            <Trash2 className="size-3.5" /> Delete
          </button>
          <button className="btn-secondary btn-sm" disabled={!sel.length} onClick={() => {
            const cs = new Set(selColors)
            setSelection(graph.shapes.filter((s) => !s.transparent && cs.has(rs?.colorOf[s.id] as number)).map((s) => s.id))
          }}>
            Same colour
          </button>
          <button className="btn-secondary btn-sm" disabled={!sel.length} onClick={() => applyEdits((x) => {
            const sc = { ...x.shapeColors }
            sel.forEach((id) => delete sc[id])
            return { ...x, shapeColors: sc, hiddenShapes: x.hiddenShapes.filter((h) => !sel.includes(h)), backgroundShapes: x.backgroundShapes.filter((h) => !sel.includes(h)), regionMerges: x.regionMerges.filter((g) => !g.some((m) => sel.includes(m))) }
          })}>
            <RotateCcw className="size-3.5" /> Reset
          </button>
        </div>
      </Section>
      <Section title="Deleted regions" aside={<Eraser className="size-3.5 text-faint" />}>
        <Stat label="Deleted" value={edits.hiddenShapes.length} />
        <Stat label="Merge groups" value={edits.regionMerges.length} />
        <button className="btn-secondary btn-sm mt-2 w-full" disabled={!edits.hiddenShapes.length} onClick={() => applyEdits((x) => ({ ...x, hiddenShapes: [] }))}>
          Restore all deleted
        </button>
      </Section>
    </div>
  )
}
