import { create } from 'zustand'
import { deriveRenderState, GraphModel, type RenderState } from '../lib/graph'
import { emptyEdits, type Edits, type ImageInfo, type JobState, type ProcessingOptions, type VectorGraphJSON } from '../lib/types'
import type { View } from '../render/renderer'

export type ToolId = 'palette' | 'background' | 'regions' | 'geometry' | 'corners' | 'symmetry' | 'shapes'
export type ViewMode = 'vector' | 'source' | 'split'

const HISTORY_LIMIT = 100

interface EditorState {
  token: string | null
  info: ImageInfo | null
  graph: VectorGraphJSON | null
  model: GraphModel | null
  rs: RenderState | null
  edits: Edits
  past: Edits[]
  future: Edits[]
  dirty: boolean
  tool: ToolId
  selection: number[]
  highlight: number[]
  view: View
  viewMode: ViewMode
  split: number
  outlines: boolean
  job: JobState | null
  options: ProcessingOptions
  canvasSize: { w: number; h: number }
  frameMs: number
  /** keep fitting to the canvas until the user zooms or pans */
  autoFit: boolean

  reset: (token: string) => void
  setInfo: (info: ImageInfo) => void
  setGraph: (g: VectorGraphJSON) => void
  setJob: (j: JobState | null) => void
  setTool: (t: ToolId) => void
  setSelection: (ids: number[]) => void
  setHighlight: (ids: number[]) => void
  setView: (v: View) => void
  setViewMode: (m: ViewMode) => void
  setSplit: (s: number) => void
  setOutlines: (b: boolean) => void
  setOptions: (o: ProcessingOptions) => void
  setCanvasSize: (w: number, h: number) => void
  setFrameMs: (ms: number) => void
  applyEdits: (fn: (e: Edits) => Edits) => void
  replaceEdits: (e: Edits) => void
  undo: () => void
  redo: () => void
  markSaved: () => void
  fit: () => void
  zoomAt: (factor: number, cx?: number, cy?: number) => void
}

const normalize = (e: Partial<Edits> | undefined): Edits => ({ ...emptyEdits(), ...(e ?? {}) })

export const useEditor = create<EditorState>((set, get) => ({
  token: null,
  info: null,
  graph: null,
  model: null,
  rs: null,
  edits: emptyEdits(),
  past: [],
  future: [],
  dirty: false,
  tool: 'palette',
  selection: [],
  highlight: [],
  view: { scale: 1, tx: 0, ty: 0 },
  viewMode: 'vector',
  split: 0.5,
  outlines: false,
  job: null,
  options: {},
  canvasSize: { w: 1, h: 1 },
  frameMs: 0,
  autoFit: true,

  reset: (token) =>
    set({ token, info: null, graph: null, model: null, rs: null, edits: emptyEdits(), past: [], future: [], dirty: false, selection: [], highlight: [], job: null, viewMode: 'vector', autoFit: true, view: { scale: 1, tx: 0, ty: 0 } }),
  setInfo: (info) => set({ info, options: info.options, edits: normalize(info.edits) }),
  setGraph: (g) => {
    const edits = get().edits
    set({ graph: g, model: new GraphModel(g), rs: deriveRenderState(g, edits), selection: [], highlight: [] })
    if (get().autoFit) get().fit()
  },
  setJob: (job) => set({ job }),
  setTool: (tool) => set((st) => ({ tool, highlight: [], selection: tool === 'regions' || tool === 'geometry' ? st.selection : [] })),
  setSelection: (selection) => set({ selection }),
  setHighlight: (highlight) => set({ highlight }),
  setView: (view) => set({ view, autoFit: false }),
  setViewMode: (viewMode) => set({ viewMode }),
  setSplit: (split) => set({ split: Math.min(0.98, Math.max(0.02, split)) }),
  setOutlines: (outlines) => set({ outlines }),
  setOptions: (options) => set({ options }),
  setCanvasSize: (w, h) => {
    set({ canvasSize: { w, h } })
    if (get().autoFit) get().fit()
  },
  setFrameMs: (frameMs) => set({ frameMs }),
  applyEdits: (fn) => {
    const { edits, past, graph } = get()
    const next = fn(structuredClone(edits))
    set({
      edits: next,
      past: [...past.slice(-HISTORY_LIMIT + 1), edits],
      future: [],
      dirty: true,
      rs: graph ? deriveRenderState(graph, next) : null,
    })
  },
  replaceEdits: (e) => {
    const g = get().graph
    set({ edits: e, past: [], future: [], dirty: true, rs: g ? deriveRenderState(g, e) : null })
  },
  undo: () => {
    const { past, edits, future, graph } = get()
    if (!past.length) return
    const prev = past[past.length - 1]
    set({ edits: prev, past: past.slice(0, -1), future: [edits, ...future], dirty: true, rs: graph ? deriveRenderState(graph, prev) : null })
  },
  redo: () => {
    const { past, edits, future, graph } = get()
    if (!future.length) return
    const next = future[0]
    set({ edits: next, past: [...past, edits], future: future.slice(1), dirty: true, rs: graph ? deriveRenderState(graph, next) : null })
  },
  markSaved: () => set({ dirty: false }),
  fit: () => {
    const { graph, canvasSize } = get()
    if (!graph) return
    const pad = 32
    const s = Math.min((canvasSize.w - pad * 2) / graph.width, (canvasSize.h - pad * 2) / graph.height)
    const scale = Math.max(0.02, Math.min(64, s))
    set({ autoFit: true, view: { scale, tx: (canvasSize.w - graph.width * scale) / 2, ty: (canvasSize.h - graph.height * scale) / 2 } })
  },
  zoomAt: (factor, cx, cy) => {
    const { view, canvasSize } = get()
    const x = cx ?? canvasSize.w / 2
    const y = cy ?? canvasSize.h / 2
    const scale = Math.max(0.02, Math.min(64, view.scale * factor))
    const k = scale / view.scale
    set({ autoFit: false, view: { scale, tx: x - (x - view.tx) * k, ty: y - (y - view.ty) * k } })
  },
}))
