import { useEffect, useState, type ReactNode } from 'react'
import { api } from '../lib/api'
import type { OptionSpec, ProcessingOptions } from '../lib/types'

export interface ExportSpec extends OptionSpec {}

let schemaPromise: Promise<{ processing: OptionSpec[]; export: ExportSpec[]; errors: unknown[] }> | null = null
export function useSchema() {
  const [schema, setSchema] = useState<{ processing: OptionSpec[]; export: ExportSpec[] } | null>(null)
  useEffect(() => {
    schemaPromise ??= api('/api/meta/options')
    schemaPromise.then(setSchema).catch(() => (schemaPromise = null))
  }, [])
  return schema
}

/** Options that change stages 1–3 (and therefore shape ids/palette indices). */
export const SEGMENTATION_ATTRS = new Set(['max_pixels', 'color_profile', 'denoise', 'max_colors', 'palette', 'color_threshold', 'min_area_px', 'gradients', 'detail'])

const LABELS: Record<string, string> = {
  max_colors: 'Maximum colours',
  color_threshold: 'Colour merge threshold (ΔE)',
  palette: 'Custom palette',
  gradients: 'Smooth gradients',
  detail: 'Detail level',
  denoise: 'Noise reduction',
  min_area_px: 'Minimum region area (px)',
  fit_tolerance: 'Curve tolerance (px)',
  subpixel: 'Sub-pixel edges',
  curves_quadratic: 'Quadratic Béziers',
  curves_cubic: 'Cubic Béziers',
  curves_arcs: 'Circular arcs',
  corners_mode: 'Corner mode',
  corners_strength: 'Correction strength',
  shapes_enabled: 'Recognise shapes',
  shapes_circle: 'Circles',
  shapes_ellipse: 'Ellipses',
  shapes_rectangle: 'Rectangles & squares',
  shapes_rounded_rectangle: 'Rounded rectangles',
  shapes_triangle: 'Triangles',
  shapes_quadrilateral: 'Quadrilaterals',
  shapes_star: 'Stars',
  symmetry_mirror: 'Mirror symmetry',
  symmetry_rotation: 'Rotational symmetry',
  symmetry_repeats: 'Repeated shapes',
  symmetry_tolerance: 'Detection tolerance (px)',
  max_pixels: 'Working resolution (px)',
}

export const labelFor = (attr: string) => LABELS[attr] ?? attr

export function Switch({ checked, onChange, label, hint, disabled }: { checked: boolean; onChange: (v: boolean) => void; label: ReactNode; hint?: string; disabled?: boolean }) {
  return (
    <label className={`flex cursor-pointer items-start justify-between gap-3 py-1.5 ${disabled ? 'opacity-50' : ''}`} title={hint}>
      <span className="text-[13px] text-ink-2">{label}</span>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        className={`relative mt-0.5 h-5 w-9 shrink-0 rounded-full p-0 transition-colors ${checked ? 'bg-accent' : 'bg-line-strong'}`}
      >
        <span className={`absolute top-0.5 left-0 size-4 rounded-full bg-white shadow transition-transform ${checked ? 'translate-x-[18px]' : 'translate-x-0.5'}`} />
      </button>
    </label>
  )
}

export function Segmented<T extends string>({ value, options, onChange, size = 'md' }: { value: T; options: { value: T; label: ReactNode }[]; onChange: (v: T) => void; size?: 'sm' | 'md' }) {
  return (
    <div className="inline-flex w-full rounded-lg border border-line bg-canvas p-0.5">
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          onClick={() => onChange(o.value)}
          className={`flex-1 rounded-md px-2 ${size === 'sm' ? 'h-7 text-xs' : 'h-8 text-[13px]'} font-medium transition-colors ${value === o.value ? 'bg-white text-ink shadow-card' : 'text-muted hover:text-ink'}`}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}

export function OptionControl({ spec, value, onChange }: { spec: OptionSpec; value: unknown; onChange: (v: unknown) => void }) {
  const label = labelFor(spec.attr)
  if (spec.type === 'boolean') return <Switch checked={!!value} onChange={onChange} label={label} hint={spec.description} />
  if (spec.type === 'enum')
    return (
      <div className="space-y-1.5 py-1.5">
        <div className="label" title={spec.description}>{label}</div>
        <Segmented value={String(value)} options={(spec.enum ?? []).map((e) => ({ value: e, label: e[0].toUpperCase() + e.slice(1) }))} onChange={onChange} size="sm" />
      </div>
    )
  if (spec.type === 'string')
    return (
      <div className="space-y-1.5 py-1.5">
        <div className="label" title={spec.description}>{label}</div>
        <textarea className="input h-20 resize-y py-2 font-mono text-xs" placeholder="#1c3f8c -> #000000; #ffc400 ~ 0.05" value={String(value ?? '')} onChange={(e) => onChange(e.target.value)} />
        <p className="text-[11px] leading-snug text-faint">{spec.description}</p>
      </div>
    )
  const min = spec.minimum ?? 0
  const max = spec.maximum ?? 100
  const step = spec.type === 'integer' ? 1 : max - min <= 1 ? 0.05 : max - min <= 10 ? 0.05 : 0.5
  const num = Number(value)
  const auto = (spec.attr === 'max_colors' || spec.attr === 'fit_tolerance' || spec.attr === 'color_threshold' || spec.attr === 'min_area_px') && num === 0
  return (
    <div className="space-y-1.5 py-1.5">
      <div className="flex items-center justify-between">
        <span className="label" title={spec.description}>{label}</span>
        <span className="font-mono text-xs tabular-nums text-ink-2">{auto ? 'auto' : spec.type === 'integer' ? num : num.toFixed(2)}</span>
      </div>
      <input type="range" className="w-full" min={min} max={spec.attr === 'max_colors' ? 64 : spec.attr === 'min_area_px' ? 200 : spec.attr === 'color_threshold' ? 40 : max} step={step} value={num} onChange={(e) => onChange(spec.type === 'integer' ? parseInt(e.target.value) : parseFloat(e.target.value))} aria-label={label} />
    </div>
  )
}

export function OptionGroup({ schema, attrs, options, onChange }: { schema: OptionSpec[]; attrs: string[]; options: ProcessingOptions; onChange: (attr: string, v: unknown) => void }) {
  return (
    <div className="divide-y divide-line/70">
      {attrs.map((a) => {
        const spec = schema.find((s) => s.attr === a)
        if (!spec) return null
        return <OptionControl key={a} spec={spec} value={options[a] ?? spec.default} onChange={(v) => onChange(a, v)} />
      })}
    </div>
  )
}

export function Section({ title, children, aside }: { title: string; children: ReactNode; aside?: ReactNode }) {
  return (
    <section className="border-b border-line px-4 py-4 last:border-b-0">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="panel-title">{title}</h3>
        {aside}
      </div>
      {children}
    </section>
  )
}

export function Stat({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex items-center justify-between py-1 text-[13px]">
      <span className="text-muted">{label}</span>
      <span className="font-mono tabular-nums text-ink-2">{value}</span>
    </div>
  )
}
