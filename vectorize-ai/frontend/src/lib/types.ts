// Vector Graph JSON (see vectorization-engine/graph.py)
export type Seg =
  | ['L', number, number]
  | ['Q', number, number, number, number]
  | ['C', number, number, number, number, number, number]
  | ['A', number, number, number, number, number] // cx cy r start sweep
  | ['E', number, number, number, number, number, number, number] // cx cy rx ry rot start sweep

export interface GraphInterface {
  id: number
  start: number
  end: number
  left: number
  right: number
  closed: boolean
  border: boolean
  p0: [number, number]
  segs: Seg[]
}

export interface Primitive {
  type: 'circle' | 'ellipse' | 'rectangle' | 'rounded_rectangle' | 'triangle' | 'quadrilateral' | 'star'
  [k: string]: unknown
}

export type PaintJSON =
  | { type: 'linear'; x1: number; y1: number; x2: number; y2: number; stops: number[][] }
  | { type: 'radial'; m: [number, number, number, number, number, number]; stops: number[][] }

export interface GraphShape {
  id: number
  color: number
  transparent: boolean
  loops: [number, number][][]
  area: number
  bbox: [number, number, number, number]
  parent: number
  parentHole: number
  depth: number
  stackHoles: number[]
  primitive?: Primitive
  symmetry?: { mirror: { angle: number; axis: string }[]; rotation: number; center: [number, number] }
  repeat?: number
  fill?: PaintJSON
}

export interface PaletteEntry {
  rgba: [number, number, number, number]
  hex: string
  count: number
}

export interface GraphStats {
  width: number
  height: number
  original_width: number
  original_height: number
  colors: number
  shapes: number
  interfaces: number
  nodes: number
  segments: number
  segment_kinds: Record<string, number>
  primitives: number
  symmetric_shapes: number
  repeated_shapes: number
  gradient_shapes?: number
  fit_tolerance: number
  timings: Record<string, number>
  analysis?: Record<string, number | boolean>
  [k: string]: unknown
}

export interface VectorGraphJSON {
  version: number
  width: number
  height: number
  scale: number
  original: [number, number]
  palette: PaletteEntry[]
  nodes: [number, number, number][]
  interfaces: GraphInterface[]
  shapes: GraphShape[]
  order: number[]
  stats: GraphStats
}

export type JobStatus = 'queued' | 'preparing' | 'processing' | 'optimizing' | 'rendering' | 'completed' | 'failed' | 'cancelled'

export interface JobState {
  id: string
  token: string
  status: JobStatus
  stage: string
  progress: number
  message: string
  error_code: string | null
  error_message: string | null
  attempts: number
  queue_position: number
  elapsed?: number
}

export interface Edits {
  paletteOverrides: Record<string, [number, number, number, number]>
  addedColors: [number, number, number, number][]
  deletedColors: number[]
  mergedColors: Record<string, number>
  shapeColors: Record<string, number>
  hiddenShapes: number[]
  backgroundShapes: number[]
  regionMerges: number[][]
}

export const emptyEdits = (): Edits => ({
  paletteOverrides: {},
  addedColors: [],
  deletedColors: [],
  mergedColors: {},
  shapeColors: {},
  hiddenShapes: [],
  backgroundShapes: [],
  regionMerges: [],
})

export type ProcessingOptions = Record<string, number | string | boolean>

export interface ImageInfo {
  token: string
  filename: string
  format: string
  width: number
  height: number
  crop: number[] | null
  status: JobStatus
  options: ProcessingOptions
  edits: Partial<Edits>
  stats: Partial<GraphStats>
  isExample: boolean
  createdAt: string
  expiresAt: string
  hasResult: boolean
  job: JobState | null
}

export interface User {
  id: number
  email: string
  name: string
  createdAt: string
}

export interface AccountSummary {
  webPlan: string
  webState: string
  apiPlan: string | null
  apiState: string
  credits: number
  periodEnd: string | null
  canManage: boolean
}

export interface OptionSpec {
  name: string
  attr: string
  type: 'integer' | 'number' | 'boolean' | 'enum' | 'string'
  description: string
  group?: string
  default: number | string | boolean
  minimum?: number
  maximum?: number
  enum?: string[]
}
