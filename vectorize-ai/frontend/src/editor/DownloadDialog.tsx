import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Download, Lock } from 'lucide-react'
import { Modal, ErrorNote, Spinner } from '../components/Chrome'
import { downloadFile } from '../lib/api'
import { useAuth } from '../store/auth'
import { Section, Segmented, Switch } from './controls'

type Fmt = 'svg' | 'pdf' | 'eps' | 'dxf' | 'png'

const FORMATS: { value: Fmt; label: string; note: string }[] = [
  { value: 'svg', label: 'SVG', note: 'Web, Illustrator, Figma, Inkscape' },
  { value: 'pdf', label: 'PDF', note: 'Print, documents (PDF 1.4)' },
  { value: 'eps', label: 'EPS', note: 'Legacy print workflows (EPSF 3.0)' },
  { value: 'dxf', label: 'DXF', note: 'CAD, laser and vinyl cutters' },
  { value: 'png', label: 'PNG', note: 'Raster rendering of the vectors' },
]

export function DownloadDialog({ open, onClose, token, filename, isExample, size }: { open: boolean; onClose: () => void; token: string; filename: string; isExample: boolean; size: [number, number] }) {
  const { user, account } = useAuth()
  const [fmt, setFmt] = useState<Fmt>('svg')
  const [svgVersion, setSvgVersion] = useState('svg_1_1')
  const [stacking, setStacking] = useState('cutouts')
  const [groupBy, setGroupBy] = useState('none')
  const [style, setStyle] = useState('fill_shapes')
  const [gap, setGap] = useState(true)
  const [prims, setPrims] = useState(true)
  const [unit, setUnit] = useState('px')
  const [scale, setScale] = useState(1)
  const [dpi, setDpi] = useState(72)
  const [pngScale, setPngScale] = useState(1)
  const [aa, setAa] = useState(true)
  const [dxf, setDxf] = useState('lines_arcs_splines')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const entitled = isExample || account?.webPlan === 'web_pro'

  const query = useMemo(() => {
    const q = new URLSearchParams({ format: fmt, 'output.size.scale': String(scale), 'output.size.unit': unit, 'output.size.dpi': String(dpi) })
    if (fmt === 'svg') {
      q.set('output.svg.version', svgVersion)
      q.set('output.shape_primitives', String(prims))
    }
    if (fmt !== 'png') {
      q.set('output.shape_stacking', stacking)
      q.set('output.group_by', groupBy)
      q.set('output.draw_style', style)
      q.set('output.gap_filler.enabled', String(gap))
    }
    if (fmt === 'png') {
      q.set('output.bitmap.anti_aliasing', String(aa))
      q.set('output.size.scale', String(pngScale))
    }
    if (fmt === 'dxf') q.set('output.dxf.compatibility_level', dxf)
    return q
  }, [fmt, scale, unit, dpi, svgVersion, prims, stacking, groupBy, style, gap, aa, pngScale, dxf])

  const pngPixels = Math.round(size[0] * pngScale) * Math.round(size[1] * pngScale)

  const go = async () => {
    setBusy(true)
    setErr('')
    try {
      await downloadFile(`/api/images/${token}/download?${query}`, `${filename.replace(/\.[^.]+$/, '')}.${fmt}`)
      onClose()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="Download">
      <div className="-mx-5 -mt-5">
        <div className="grid grid-cols-5 border-b border-line">
          {FORMATS.map((f) => (
            <button key={f.value} onClick={() => setFmt(f.value)} className={`border-b-2 py-3 text-sm font-semibold ${fmt === f.value ? 'border-accent text-ink' : 'border-transparent text-muted hover:text-ink'}`}>
              {f.label}
            </button>
          ))}
        </div>
        <p className="px-5 pt-3 text-xs text-muted">{FORMATS.find((f) => f.value === fmt)!.note}</p>
        {fmt === 'svg' && (
          <Section title="SVG">
            <Segmented value={svgVersion} onChange={setSvgVersion} size="sm" options={[{ value: 'svg_1_0', label: '1.0' }, { value: 'svg_1_1', label: '1.1' }, { value: 'svg_tiny_1_2', label: 'Tiny 1.2' }]} />
            <Switch checked={prims} onChange={setPrims} label="Native circles, rectangles and polygons" />
          </Section>
        )}
        {fmt !== 'png' && (
          <Section title="Structure">
            <div className="space-y-2">
              <div className="label">Shape stacking</div>
              <Segmented value={stacking} onChange={setStacking} size="sm" options={[{ value: 'cutouts', label: 'Cut-outs' }, { value: 'stacked', label: 'Stacked' }]} />
              <div className="label">Group by</div>
              <Segmented value={groupBy} onChange={setGroupBy} size="sm" options={[{ value: 'none', label: 'None' }, { value: 'color', label: 'Colour' }, { value: 'parent', label: 'Parent' }, { value: 'layer', label: 'Layer' }]} />
              <div className="label">Draw style</div>
              <Segmented value={style} onChange={setStyle} size="sm" options={[{ value: 'fill_shapes', label: 'Fill' }, { value: 'stroke_shapes', label: 'Outline shapes' }, { value: 'stroke_edges', label: 'Edges' }]} />
              {stacking === 'cutouts' && style === 'fill_shapes' && <Switch checked={gap} onChange={setGap} label="Gap filler (hide anti-aliasing seams)" />}
            </div>
          </Section>
        )}
        {fmt === 'dxf' && (
          <Section title="DXF primitives">
            <Segmented value={dxf} onChange={setDxf} size="sm" options={[{ value: 'lines', label: 'Lines' }, { value: 'lines_arcs', label: '+ Arcs' }, { value: 'lines_arcs_splines', label: '+ Splines' }]} />
          </Section>
        )}
        {fmt === 'png' ? (
          <Section title="Bitmap">
            <div className="flex items-center justify-between">
              <span className="label">Scale</span>
              <span className="font-mono text-xs">{pngScale}× · {Math.round(size[0] * pngScale)}×{Math.round(size[1] * pngScale)}</span>
            </div>
            <input type="range" className="w-full" min={0.25} max={8} step={0.25} value={pngScale} onChange={(e) => setPngScale(parseFloat(e.target.value))} aria-label="PNG scale" />
            {pngPixels > 52_000_000 && <p className="text-xs text-danger">Above the 52 MP limit.</p>}
            <Switch checked={aa} onChange={setAa} label="Anti-aliasing" />
          </Section>
        ) : (
          <Section title="Size">
            <div className="grid grid-cols-3 gap-2">
              <label className="space-y-1">
                <span className="label">Scale</span>
                <input className="input h-8" type="number" min={0.01} step={0.1} value={scale} onChange={(e) => setScale(Math.max(0.01, parseFloat(e.target.value) || 1))} />
              </label>
              <label className="space-y-1">
                <span className="label">Unit</span>
                <select className="input h-8" value={unit} onChange={(e) => setUnit(e.target.value)}>
                  {['px', 'pt', 'in', 'cm', 'mm'].map((u) => (
                    <option key={u}>{u}</option>
                  ))}
                </select>
              </label>
              <label className="space-y-1">
                <span className="label">DPI</span>
                <input className="input h-8" type="number" min={1} value={dpi} onChange={(e) => setDpi(Math.max(1, parseFloat(e.target.value) || 72))} />
              </label>
            </div>
            <p className="mt-2 text-[11px] text-faint">Output: {(size[0] * scale).toFixed(0)} × {(size[1] * scale).toFixed(0)} px{unit !== 'px' ? ` at ${dpi} dpi` : ''}</p>
          </Section>
        )}
      </div>
      {!entitled && (
        <div className="mt-4 rounded-xl border border-line bg-canvas p-4 text-sm">
          <div className="flex items-center gap-2 font-medium">
            <Lock className="size-4" /> Downloads require Pro
          </div>
          <p className="mt-1 text-muted">Processing and previews are free. Pro unlocks unlimited downloads in every format for $9.99/month. Example images are free to download.</p>
          <div className="mt-3 flex gap-2">
            <Link to="/pricing" className="btn-primary btn-sm">
              View plans
            </Link>
            {!user && (
              <Link to="/signin" className="btn-secondary btn-sm">
                Sign in
              </Link>
            )}
          </div>
        </div>
      )}
      {err && (
        <div className="mt-3">
          <ErrorNote>{err}</ErrorNote>
        </div>
      )}
      <div className="mt-4 flex justify-end gap-2">
        <button className="btn-secondary" onClick={onClose}>
          Cancel
        </button>
        <button className="btn-primary" onClick={go} disabled={busy || !entitled || (fmt === 'png' && pngPixels > 52_000_000)}>
          {busy ? <Spinner /> : <Download className="size-4" />} Download {fmt.toUpperCase()}
        </button>
      </div>
    </Modal>
  )
}
