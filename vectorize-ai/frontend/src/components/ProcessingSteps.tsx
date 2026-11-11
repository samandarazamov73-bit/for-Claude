import { Check, X } from 'lucide-react'
import type { JobState } from '../lib/types'
import { Spinner } from './Chrome'

export const PHASES = [
  { key: 'uploading', label: 'Uploading', hint: 'Sending the file' },
  { key: 'preparing', label: 'Preparing', hint: 'Decoding, colour management, noise analysis' },
  { key: 'processing', label: 'Processing', hint: 'Segmentation, vector graph, sub-pixel curves' },
  { key: 'optimizing', label: 'Optimizing', hint: 'Shapes, symmetry, final cleanup' },
  { key: 'rendering', label: 'Rendering', hint: 'Writing the result' },
] as const

const ORDER = ['queued', 'uploading', 'preparing', 'processing', 'optimizing', 'rendering', 'completed']

export interface ProgressView {
  status: string // uploading | queued | preparing | ... | completed | failed | cancelled
  progress: number // 0..1 overall (server) or upload fraction
  message: string
  job?: JobState | null
}

export function ProcessingSteps({ view, onCancel, onRetry }: { view: ProgressView; onCancel?: () => void; onRetry?: () => void }) {
  const idx = ORDER.indexOf(view.status === 'queued' ? 'preparing' : view.status)
  const failed = view.status === 'failed' || view.status === 'cancelled'
  const pct = Math.round(Math.min(1, Math.max(0, view.progress)) * 100)
  return (
    <div className="card mx-auto w-full max-w-md p-5" role="status" aria-live="polite">
      <div className="mb-4 flex items-baseline justify-between">
        <div className="text-[15px] font-semibold">{failed ? (view.status === 'cancelled' ? 'Cancelled' : 'Processing failed') : view.status === 'completed' ? 'Completed' : 'Vectorizing'}</div>
        {!failed && <div className="font-mono text-sm text-muted tabular-nums">{pct}%</div>}
      </div>
      <div className="mb-5 h-1.5 overflow-hidden rounded-full bg-subtle">
        <div className={`h-full rounded-full transition-[width] duration-300 ${failed ? 'bg-danger' : 'bg-accent'}`} style={{ width: `${failed ? 100 : pct}%` }} />
      </div>
      <ol className="space-y-2.5">
        {PHASES.map((p) => {
          const pi = ORDER.indexOf(p.key)
          const done = !failed && (idx > pi || view.status === 'completed')
          const active = !failed && idx === pi
          const errHere = failed && (idx === pi || (idx < 0 && p.key === 'preparing'))
          return (
            <li key={p.key} className="flex items-start gap-3">
              <span className={`mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border ${done ? 'border-ok bg-ok text-white' : active ? 'border-accent text-accent' : errHere ? 'border-danger bg-danger text-white' : 'border-line text-faint'}`}>
                {done ? <Check className="size-3" strokeWidth={3} /> : active ? <Spinner className="size-3" /> : errHere ? <X className="size-3" strokeWidth={3} /> : null}
              </span>
              <div className="min-w-0">
                <div className={`text-sm ${active || done ? 'text-ink' : 'text-faint'}`}>{p.label}</div>
                {active && <div className="truncate text-xs text-muted">{view.message || p.hint}</div>}
              </div>
            </li>
          )
        })}
      </ol>
      {view.job?.queue_position ? <p className="mt-4 text-xs text-muted">Queued – position {view.job.queue_position}</p> : null}
      {failed && (
        <div className="mt-4 rounded-lg bg-danger/5 px-3 py-2 text-sm text-danger">
          {view.job?.error_message || view.message}
          {view.job?.error_code && <span className="ml-1 font-mono text-xs opacity-70">({view.job.error_code})</span>}
        </div>
      )}
      <div className="mt-4 flex justify-end gap-2">
        {!failed && view.status !== 'completed' && onCancel && (
          <button className="btn-secondary btn-sm" onClick={onCancel}>
            Cancel
          </button>
        )}
        {failed && onRetry && (
          <button className="btn-primary btn-sm" onClick={onRetry}>
            Retry
          </button>
        )}
      </div>
    </div>
  )
}
