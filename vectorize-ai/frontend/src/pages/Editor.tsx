import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation, useParams } from 'react-router-dom'
import {
  ArrowLeft,
  Columns2,
  Download,
  Eraser,
  FlipHorizontal2,
  Maximize,
  MousePointer2,
  Palette,
  Redo2,
  Scan,
  Shapes,
  Spline,
  Undo2,
  ZoomIn,
  ZoomOut,
} from 'lucide-react'
import { ErrorNote, Logo, Spinner } from '../components/Chrome'
import { ProcessingSteps } from '../components/ProcessingSteps'
import { CanvasView } from '../editor/CanvasView'
import { EditorContext } from '../editor/context'
import { SEGMENTATION_ATTRS, Segmented, useSchema } from '../editor/controls'
import { DownloadDialog } from '../editor/DownloadDialog'
import { PalettePanel } from '../editor/tools/PalettePanel'
import { CornersPanel, GeometryPanel, ShapesPanel, SymmetryPanel } from '../editor/tools/ProcessingPanels'
import { BackgroundPanel, RegionsPanel } from '../editor/tools/RegionPanels'
import { api, ApiError, getGraph, getImage, watchJob } from '../lib/api'
import { emptyEdits, type JobState, type ProcessingOptions } from '../lib/types'
import { useAuth } from '../store/auth'
import { useEditor, type ToolId } from '../store/editor'

const TOOLS: { id: ToolId; label: string; icon: typeof Palette }[] = [
  { id: 'palette', label: 'Palette', icon: Palette },
  { id: 'background', label: 'Background', icon: Eraser },
  { id: 'regions', label: 'Regions', icon: MousePointer2 },
  { id: 'geometry', label: 'Geometry', icon: Spline },
  { id: 'corners', label: 'Corners', icon: Scan },
  { id: 'symmetry', label: 'Symmetry', icon: FlipHorizontal2 },
  { id: 'shapes', label: 'Shapes', icon: Shapes },
]

const TERMINAL = new Set(['completed', 'failed', 'cancelled'])

export default function Editor() {
  const { token = '' } = useParams()
  const location = useLocation() as { state?: { jobId?: string } }
  const schema = useSchema()
  const refreshAuth = useAuth((s) => s.refresh)
  const st = useEditor()
  const [source, setSource] = useState<ImageBitmap | null>(null)
  const [loadError, setLoadError] = useState('')
  const [download, setDownload] = useState(false)
  const [panelOpen, setPanelOpen] = useState(true)
  const stopWatch = useRef<(() => void) | null>(null)
  const saveTimer = useRef<number | undefined>(undefined)

  const loadResult = useCallback(async () => {
    const [g, blob] = await Promise.all([getGraph(token), fetch(`/api/images/${token}/source.png`).then((r) => (r.ok ? r.blob() : null))])
    useEditor.getState().setGraph(g)
    if (blob) setSource(await createImageBitmap(blob))
  }, [token])

  const follow = useCallback(
    (jobId: string, after?: () => void) => {
      stopWatch.current?.()
      stopWatch.current = watchJob(jobId, async (j: JobState) => {
        useEditor.getState().setJob(j)
        if (j.status === 'completed') {
          try {
            const info = await getImage(token)
            useEditor.setState({ info, options: info.options })
            await loadResult()
            after?.()
          } catch (e) {
            setLoadError((e as Error).message)
          }
        }
      })
    },
    [token, loadResult],
  )

  // initial load
  useEffect(() => {
    useEditor.getState().reset(token)
    setSource(null)
    setLoadError('')
    refreshAuth()
    let alive = true
    getImage(token)
      .then(async (info) => {
        if (!alive) return
        useEditor.getState().setInfo(info)
        useEditor.getState().setJob(info.job)
        if (info.hasResult) await loadResult()
        const jobId = info.job && !TERMINAL.has(info.job.status) ? info.job.id : location.state?.jobId && !info.hasResult ? location.state.jobId : null
        if (jobId) follow(jobId)
      })
      .catch((e) => setLoadError(e instanceof ApiError && e.status === 404 ? 'This image does not exist or has expired.' : (e as Error).message))
    return () => {
      alive = false
      stopWatch.current?.()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token])

  // persist edits (debounced)
  const edits = st.edits
  const dirty = st.dirty
  useEffect(() => {
    if (!dirty) return
    window.clearTimeout(saveTimer.current)
    saveTimer.current = window.setTimeout(() => {
      api(`/api/images/${token}/edits`, { method: 'PUT', body: JSON.stringify(edits), headers: { 'Content-Type': 'application/json' } })
        .then(() => useEditor.getState().markSaved())
        .catch(() => undefined)
    }, 600)
    return () => window.clearTimeout(saveTimer.current)
  }, [edits, dirty, token])

  const busy = !!st.job && !TERMINAL.has(st.job.status)

  const reprocess = useCallback(
    async (options: ProcessingOptions) => {
      const cur = useEditor.getState().options
      const resets = Object.keys(options).some((k) => SEGMENTATION_ATTRS.has(k) && options[k] !== cur[k])
      try {
        const r = await api<{ jobId: string }>(`/api/images/${token}/reprocess`, { method: 'POST', json: { options } })
        useEditor.setState({ options })
        follow(r.jobId, () => {
          if (resets) useEditor.getState().replaceEdits(emptyEdits())
        })
      } catch (e) {
        setLoadError((e as Error).message)
      }
    },
    [token, follow],
  )

  // keyboard shortcuts
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement) return
      const s = useEditor.getState()
      const mod = e.ctrlKey || e.metaKey
      if (mod && e.key.toLowerCase() === 'z') {
        e.preventDefault()
        if (e.shiftKey) s.redo()
        else s.undo()
      } else if (mod && e.key.toLowerCase() === 'y') {
        e.preventDefault()
        s.redo()
      } else if (e.key === '+' || e.key === '=') s.zoomAt(1.25)
      else if (e.key === '-') s.zoomAt(0.8)
      else if (e.key === '0') s.fit()
      else if (e.key.toLowerCase() === 'b') s.setViewMode(s.viewMode === 'split' ? 'vector' : 'split')
      else if (e.key === 'Escape') {
        s.setSelection([])
        s.setHighlight([])
      } else if ((e.key === 'Delete' || e.key === 'Backspace') && s.selection.length) {
        const sel = s.selection
        s.applyEdits((x) => ({ ...x, hiddenShapes: [...new Set([...x.hiddenShapes, ...sel])] }))
        s.setSelection([])
      }
    }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [])

  const onShapeClick = useCallback((id: number | null, e: { shift: boolean }) => {
    const s = useEditor.getState()
    if (s.tool === 'background') {
      if (id === null) return
      s.applyEdits((x) => ({ ...x, backgroundShapes: x.backgroundShapes.includes(id) ? x.backgroundShapes.filter((b) => b !== id) : [...x.backgroundShapes, id] }))
      return
    }
    if (id === null) {
      s.setSelection([])
      return
    }
    if (s.tool === 'palette') {
      const c = s.rs?.colorOf[id]
      if (c !== undefined) s.setHighlight(s.graph!.shapes.filter((sh) => s.rs?.colorOf[sh.id] === c).map((sh) => sh.id))
      return
    }
    if (e.shift) s.setSelection(s.selection.includes(id) ? s.selection.filter((x) => x !== id) : [...s.selection, id])
    else s.setSelection([id])
    if (s.tool !== 'regions' && s.tool !== 'geometry') s.setTool('regions')
  }, [])

  const ctx = useMemo(() => (schema ? { token, schema: schema.processing, busy, reprocess } : null), [token, schema, busy, reprocess])
  const info = st.info
  const graph = st.graph
  const job = st.job
  const pct = Math.round((job?.progress ?? 0) * 100)

  if (loadError && !graph) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-4 p-6">
        <Logo />
        <ErrorNote>{loadError}</ErrorNote>
        <Link to="/" className="btn-primary">
          Upload a new image
        </Link>
      </div>
    )
  }

  const Panel = { palette: PalettePanel, background: BackgroundPanel, regions: RegionsPanel, geometry: GeometryPanel, corners: CornersPanel, symmetry: SymmetryPanel, shapes: ShapesPanel }[st.tool]

  return (
    <div className="flex h-[100dvh] flex-col bg-white text-ink">
      {/* top bar */}
      <header className="flex h-12 shrink-0 items-center gap-2 border-b border-line px-2 sm:px-3">
        <Link to="/" className="icon-btn" title="Back">
          <ArrowLeft className="size-4" />
        </Link>
        <div className="hidden sm:block">
          <Logo compact />
        </div>
        <div className="min-w-0 px-1">
          <div className="truncate text-[13px] font-medium">{info?.filename ?? 'Loading…'}</div>
          <div className="hidden text-[11px] text-faint sm:block">{info ? `${info.width} × ${info.height} · ${info.format}${info.isExample ? ' · example' : ''}` : ''}</div>
        </div>
        <div className="mx-1 hidden h-5 w-px bg-line sm:block" />
        <button className="icon-btn" title="Undo (Ctrl+Z)" disabled={!st.past.length} onClick={st.undo}>
          <Undo2 className="size-4" />
        </button>
        <button className="icon-btn" title="Redo (Ctrl+Shift+Z)" disabled={!st.future.length} onClick={st.redo}>
          <Redo2 className="size-4" />
        </button>
        <div className="ml-auto hidden w-64 md:block">
          <Segmented
            size="sm"
            value={st.viewMode}
            onChange={st.setViewMode}
            options={[
              { value: 'vector', label: 'Vector' },
              { value: 'split', label: <span className="inline-flex items-center gap-1"><Columns2 className="size-3.5" /> Before/After</span> },
              { value: 'source', label: 'Original' },
            ]}
          />
        </div>
        <div className="ml-auto flex items-center gap-0.5 md:ml-2">
          <button className="icon-btn" title="Zoom out (-)" onClick={() => st.zoomAt(0.8)}>
            <ZoomOut className="size-4" />
          </button>
          <button className="icon-btn" title="Zoom in (+)" onClick={() => st.zoomAt(1.25)}>
            <ZoomIn className="size-4" />
          </button>
          <button className="icon-btn" title="Fit to screen (0)" onClick={st.fit}>
            <Maximize className="size-4" />
          </button>
        </div>
        <button className="btn-primary btn-sm ml-1" disabled={!graph} onClick={() => setDownload(true)}>
          <Download className="size-4" /> <span className="hidden sm:inline">Download</span>
        </button>
      </header>

      <div className="flex min-h-0 flex-1 flex-col md:flex-row">
        {/* tool rail */}
        <nav className="order-3 flex shrink-0 overflow-x-auto border-t border-line bg-white md:order-none md:w-[76px] md:flex-col md:overflow-visible md:border-t-0 md:border-r md:py-2" aria-label="Tools">
          {TOOLS.map((t) => (
            <button
              key={t.id}
              onClick={() => {
                if (st.tool === t.id) setPanelOpen(!panelOpen)
                else {
                  st.setTool(t.id)
                  setPanelOpen(true)
                }
              }}
              className={`flex min-w-[64px] flex-1 flex-col items-center gap-1 px-1 py-2 text-[11px] font-medium transition-colors md:flex-none ${st.tool === t.id ? 'text-accent' : 'text-muted hover:text-ink'}`}
              aria-pressed={st.tool === t.id}
            >
              <span className={`flex size-9 items-center justify-center rounded-lg ${st.tool === t.id ? 'bg-accent-soft' : ''}`}>
                <t.icon className="size-[18px]" strokeWidth={1.8} />
              </span>
              {t.label}
            </button>
          ))}
        </nav>

        {/* canvas */}
        <main className="relative order-1 min-h-0 flex-1 md:order-none">
          <CanvasView source={source} onShapeClick={onShapeClick} />
          {!graph && (
            <div className="absolute inset-0 flex items-center justify-center bg-canvas/95 p-4">
              {job ? (
                <ProcessingSteps
                  view={{ status: job.status, progress: job.progress, message: job.message, job }}
                  onCancel={() => api(`/api/jobs/${job.id}/cancel`, { method: 'POST' })}
                  onRetry={async () => {
                    const r = await api<{ jobId: string }>(`/api/jobs/${job.id}/retry`, { method: 'POST' })
                    follow(r.jobId)
                  }}
                />
              ) : (
                <Spinner className="size-6 text-muted" />
              )}
            </div>
          )}
          {graph && busy && job && (
            <div className="absolute top-3 left-1/2 flex -translate-x-1/2 items-center gap-2 rounded-full border border-line bg-white/95 px-3 py-1.5 text-xs shadow-pop">
              <Spinner className="size-3.5 text-accent" /> {job.message || 'Updating'} · {pct}%
              <button className="ml-1 text-muted hover:text-ink" onClick={() => api(`/api/jobs/${job.id}/cancel`, { method: 'POST' })}>
                Cancel
              </button>
            </div>
          )}
          {graph && job?.status === 'failed' && (
            <div className="absolute top-3 left-1/2 w-[min(90%,420px)] -translate-x-1/2">
              <ErrorNote>Update failed: {job.error_message}</ErrorNote>
            </div>
          )}
          <div className="absolute right-3 bottom-3 md:hidden">
            <Segmented size="sm" value={st.viewMode} onChange={st.setViewMode} options={[{ value: 'vector', label: 'Vector' }, { value: 'split', label: 'Split' }, { value: 'source', label: 'Orig.' }]} />
          </div>
        </main>

        {/* tool panel */}
        {panelOpen && (
          <aside className="order-2 max-h-[42vh] shrink-0 overflow-y-auto border-t border-line bg-white md:order-none md:max-h-none md:w-[320px] md:border-t-0 md:border-l">
            <div className="flex items-center justify-between border-b border-line px-4 py-3">
              <h2 className="text-[13px] font-semibold">{TOOLS.find((t) => t.id === st.tool)?.label}</h2>
              <button className="text-xs text-muted hover:text-ink md:hidden" onClick={() => setPanelOpen(false)}>
                Hide
              </button>
            </div>
            {graph && ctx ? (
              <EditorContext.Provider value={ctx}>
                <Panel />
              </EditorContext.Provider>
            ) : (
              <div className="p-4 text-[13px] text-muted">Tools become available when processing finishes.</div>
            )}
          </aside>
        )}
      </div>

      {/* status bar */}
      <footer className="hidden h-7 shrink-0 items-center gap-4 border-t border-line bg-canvas px-3 font-mono text-[11px] text-muted md:flex">
        <span>{Math.round(st.view.scale * 100 * (graph ? graph.scale : 1))}%</span>
        <span>{info ? `${info.width}×${info.height}px` : '–'}{graph && graph.scale < 1 ? ` (working ${graph.width}×${graph.height})` : ''}</span>
        <span>{graph ? `${graph.stats.colors} colours` : ''}</span>
        <span>{graph ? `${graph.stats.shapes} shapes` : ''}</span>
        <span>{graph ? `${graph.stats.segments} segments` : ''}</span>
        {st.selection.length > 0 && <span>{st.selection.length} selected</span>}
        <span className="ml-auto">{busy ? `${job?.status} ${pct}%` : job?.status === 'failed' ? 'error' : graph ? 'ready' : 'processing'}</span>
        <span title="Renderer">{(window as any).__vzRenderer === 'offscreen-worker' ? 'worker' : 'main'} · {st.frameMs.toFixed(1)} ms</span>
        <span>{st.dirty ? 'saving…' : 'saved'}</span>
      </footer>

      {info && graph && (
        <DownloadDialog open={download} onClose={() => setDownload(false)} token={token} filename={info.filename} isExample={info.isExample} size={[info.crop ? info.crop[2] : info.width, info.crop ? info.crop[3] : info.height]} />
      )}
    </div>
  )
}
