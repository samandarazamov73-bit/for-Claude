import { createContext, useContext } from 'react'
import type { OptionSpec, ProcessingOptions } from '../lib/types'

export interface EditorCtx {
  token: string
  schema: OptionSpec[]
  busy: boolean
  /** re-run the pipeline with new options; geometry-only changes keep edits */
  reprocess: (options: ProcessingOptions) => void
}

export const EditorContext = createContext<EditorCtx | null>(null)

export function useEditorCtx(): EditorCtx {
  const c = useContext(EditorContext)
  if (!c) throw new Error('EditorContext missing')
  return c
}
