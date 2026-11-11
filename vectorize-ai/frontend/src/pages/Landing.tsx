import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ArrowRight, Boxes, CircleDot, Crosshair, FlipHorizontal2, Layers3, Scan, Shapes, SplinePointer } from 'lucide-react'
import { ErrorNote, Footer, Header } from '../components/Chrome'
import { PreCropDialog } from '../components/PreCropDialog'
import { ProcessingSteps, type ProgressView } from '../components/ProcessingSteps'
import { UploadZone } from '../components/UploadZone'
import { api, ApiError, uploadImage, type UploadResult } from '../lib/api'
import { MAX_FILE_BYTES, MAX_UPLOAD_PIXELS, MAX_WORKING_PIXELS, formatBytes, formatInt, probeImage, type Probe } from '../lib/probe'

interface Example {
  name: string
  title: string
  thumbnail: string
}

export function useUploadFlow() {
  const nav = useNavigate()
  const [progress, setProgress] = useState<ProgressView | null>(null)
  const [error, setError] = useState('')
  const [crop, setCrop] = useState<{ file: File; probe: Probe } | null>(null)
  const abort = useRef<AbortController | null>(null)

  const go = useCallback((r: UploadResult) => nav(`/images/${r.token}`, { state: { jobId: r.jobId, filename: r.filename } }), [nav])
  const fail = (e: unknown) => {
    setProgress(null)
    setError(e instanceof ApiError ? e.message : String(e))
  }

  const upload = useCallback(
    async (file: File, rect: [number, number, number, number] | null) => {
      abort.current = new AbortController()
      setProgress({ status: 'uploading', progress: 0, message: `Uploading ${file.name} (${formatBytes(file.size)})` })
      try {
        const r = await uploadImage(file, file.name || 'image', {
          crop: rect,
          signal: abort.current.signal,
          onProgress: (f) => setProgress({ status: 'uploading', progress: f * 0.05, message: `Uploading… ${Math.round(f * 100)}%` }),
        })
        go(r)
      } catch (e) {
        if (e instanceof ApiError && e.code === 'aborted') setProgress(null)
        else fail(e)
      }
    },
    [go],
  )

  const startFile = useCallback(
    async (file: File) => {
      setError('')
      if (file.size > MAX_FILE_BYTES) return setError(`This file is ${formatBytes(file.size)}; the limit is 30 MB.`)
      if (file.size === 0) return setError('The file is empty.')
      setProgress({ status: 'uploading', progress: 0, message: 'Reading image…' })
      const probe = await probeImage(file)
      if (probe) {
        const px = probe.width * probe.height
        if (px > MAX_UPLOAD_PIXELS) {
          setProgress(null)
          return setError(`The image has ${formatInt(px)} pixels; the maximum is ${formatInt(MAX_UPLOAD_PIXELS)}.`)
        }
        if (px > MAX_WORKING_PIXELS) {
          setProgress(null)
          setCrop({ file, probe })
          return
        }
        probe.preview.close()
      }
      await upload(file, null)
    },
    [upload],
  )

  const startUrl = useCallback(
    async (url: string) => {
      setError('')
      setProgress({ status: 'uploading', progress: 0.01, message: 'Downloading image from URL…' })
      try {
        go(await api<UploadResult>('/api/images/from-url', { method: 'POST', json: { url } }))
      } catch (e) {
        fail(e)
      }
    },
    [go],
  )

  const startExample = useCallback(
    async (name: string) => {
      setError('')
      setProgress({ status: 'uploading', progress: 0.02, message: 'Loading example…' })
      try {
        go(await api<UploadResult>(`/api/examples/${name}`, { method: 'POST' }))
      } catch (e) {
        fail(e)
      }
    },
    [go],
  )

  const cropDialog = (
    <PreCropDialog
      open={!!crop}
      preview={crop?.probe.preview ?? null}
      width={crop?.probe.width ?? 1}
      height={crop?.probe.height ?? 1}
      onCancel={() => {
        crop?.probe.preview.close()
        setCrop(null)
      }}
      onConfirm={(rect) => {
        const f = crop!.file
        crop?.probe.preview.close()
        setCrop(null)
        upload(f, rect)
      }}
    />
  )
  return { progress, error, startFile, startUrl, startExample, cropDialog, cancel: () => abort.current?.abort() }
}

const FEATURES = [
  { icon: Layers3, title: 'Anti-aliasing aware colours', text: 'Flat areas define the palette; edge pixels are solved as two-colour mixtures, so no halo slivers appear between colours.' },
  { icon: Boxes, title: 'Shared-boundary vector graph', text: 'Every border between two regions is stored once and used by both shapes — gaps and overlaps are impossible by construction.' },
  { icon: Crosshair, title: 'Sub-pixel edges', text: 'Pixel coverage from anti-aliasing places curves with sub-pixel accuracy; junctions are solved as least-squares intersections.' },
  { icon: SplinePointer, title: 'Clean curves', text: 'Lines, circular arcs and G1-continuous Béziers with tangent matching, fairing and adaptive simplification.' },
  { icon: Scan, title: 'Corner restoration', text: 'Corners are classified as sharp or rounded; sharp ones are rebuilt as exact vertices, with adjustable strength.' },
  { icon: Shapes, title: 'Shape recognition', text: 'Circles, ellipses, rectangles, rounded rectangles, triangles, quadrilaterals and stars become exact geometry.' },
  { icon: FlipHorizontal2, title: 'Symmetry & repeats', text: 'Mirror and rotational symmetry are detected and enforced; repeated shapes are made exact copies.' },
  { icon: CircleDot, title: 'Real exports', text: 'SVG 1.0/1.1/Tiny 1.2, PDF 1.4, EPS 3.0, DXF (lines, arcs, splines) and anti-aliased PNG up to 52 MP.' },
]

export default function Landing() {
  const flow = useUploadFlow()
  const [examples, setExamples] = useState<Example[]>([])
  useEffect(() => {
    api<Example[]>('/api/examples').then(setExamples).catch(() => setExamples([]))
  }, [])

  return (
    <div className="min-h-screen bg-white">
      <Header />
      <main>
        <section className="relative border-b border-line bg-[linear-gradient(to_bottom,#f6f7f9,#ffffff)]">
          <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(#e5e7eb_1px,transparent_1px)] [background-size:20px_20px] [mask-image:linear-gradient(to_bottom,black,transparent)] opacity-60" />
          <div className="relative mx-auto max-w-4xl px-4 pb-14 pt-12 sm:px-6 sm:pt-16">
            <div className="mb-8 text-center">
              <div className="mb-3 inline-flex items-center gap-2 rounded-full border border-line bg-white px-3 py-1 text-xs text-muted shadow-card">
                <span className="size-1.5 rounded-full bg-ok" /> Free to upload, process and preview
              </div>
              <h1 className="text-balance text-3xl font-semibold tracking-tight sm:text-[44px] sm:leading-[1.1]">Turn pixels into precise vectors</h1>
              <p className="mx-auto mt-3 max-w-xl text-balance text-[15px] text-muted sm:text-base">Upload a logo, icon or illustration. Get clean, editable SVG, PDF, EPS and DXF — with exact shapes, sharp corners and no gaps.</p>
            </div>
            {flow.progress ? (
              <div className="py-10">
                <ProcessingSteps view={flow.progress} onCancel={flow.progress.status === 'uploading' ? flow.cancel : undefined} />
              </div>
            ) : (
              <UploadZone onFile={flow.startFile} onUrl={flow.startUrl} />
            )}
            {flow.error && (
              <div className="mt-3">
                <ErrorNote>{flow.error}</ErrorNote>
              </div>
            )}
            {examples.length > 0 && !flow.progress && (
              <div className="mt-8">
                <div className="mb-3 flex items-center justify-between">
                  <span className="panel-title">Try an example</span>
                  <span className="text-xs text-faint">Examples are free to download</span>
                </div>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                  {examples.map((ex) => (
                    <button key={ex.name} onClick={() => flow.startExample(ex.name)} className="group overflow-hidden rounded-xl border border-line bg-white text-left shadow-card transition hover:-translate-y-0.5 hover:border-line-strong hover:shadow-pop">
                      <div className="checker aspect-[4/3] overflow-hidden">
                        <img src={ex.thumbnail} alt={ex.title} className="size-full object-contain p-3 transition group-hover:scale-[1.03]" loading="lazy" />
                      </div>
                      <div className="flex items-center justify-between border-t border-line px-3 py-2 text-[13px]">
                        <span className="truncate">{ex.title}</span>
                        <ArrowRight className="size-3.5 shrink-0 text-faint group-hover:text-ink" />
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>
        </section>

        <section id="features" className="mx-auto max-w-6xl px-4 py-16 sm:px-6">
          <div className="mb-10 max-w-2xl">
            <div className="panel-title mb-2">Engine</div>
            <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">A real vectorization pipeline</h2>
            <p className="mt-2 text-muted">Decode → preprocess → colour segmentation → boundary topology → sub-pixel sampling → curve optimisation → shape recognition → symmetry → final optimisation. Each stage reports real progress.</p>
          </div>
          <div className="grid gap-px overflow-hidden rounded-2xl border border-line bg-line sm:grid-cols-2 lg:grid-cols-4">
            {FEATURES.map((f) => (
              <div key={f.title} className="bg-white p-5">
                <f.icon className="mb-3 size-5 text-accent" strokeWidth={1.7} />
                <div className="text-[15px] font-semibold">{f.title}</div>
                <p className="mt-1.5 text-sm leading-relaxed text-muted">{f.text}</p>
              </div>
            ))}
          </div>
        </section>

        <section id="formats" className="border-y border-line bg-canvas">
          <div className="mx-auto grid max-w-6xl gap-8 px-4 py-14 sm:px-6 md:grid-cols-2">
            <div>
              <div className="panel-title mb-2">Formats</div>
              <h2 className="text-2xl font-semibold tracking-tight">In and out</h2>
              <p className="mt-2 text-muted">Up to 30 MB and 33.5 MP per upload. Large images open a pre-crop step so you can keep full detail where it matters.</p>
            </div>
            <div className="card divide-y divide-line">
              {[
                ['Input', 'PNG, JPEG, GIF, BMP, WebP, TIFF — alpha channel and ICC profiles supported'],
                ['SVG', '1.0, 1.1, Tiny 1.2 · cut-outs or stacked · grouping by colour, parent or layer'],
                ['PDF', 'PDF 1.4 vector paths with true transparency'],
                ['EPS', 'EPSF 3.0 / PostScript Level 3'],
                ['DXF', 'Lines · lines + arcs · lines + arcs + splines'],
                ['PNG', 'Anti-aliased or crisp rendering of the vectors, up to 52 MP'],
              ].map(([k, v]) => (
                <div key={k} className="flex gap-4 px-4 py-3 text-sm">
                  <span className="w-14 shrink-0 font-mono text-[13px] font-medium">{k}</span>
                  <span className="text-muted">{v}</span>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section className="mx-auto max-w-6xl px-4 py-16 sm:px-6">
          <div className="grid items-center gap-8 md:grid-cols-[1.1fr_1fr]">
            <div>
              <div className="panel-title mb-2">Editor</div>
              <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">Refine the result before you export</h2>
              <ul className="mt-4 space-y-2 text-[15px] text-muted">
                <li>• Palette: recolour, merge, delete or add colours; explore it on a perceptual map</li>
                <li>• Background removal, region selection, recolouring and merging</li>
                <li>• Geometry detail, corner handling, symmetry and shape recognition settings</li>
                <li>• Before/after slider with synchronised zoom, undo/redo</li>
              </ul>
            </div>
            <div className="card p-5 text-sm text-muted">
              <div className="mb-2 font-medium text-ink">Plans</div>
              Processing and previews are free. Downloads need <b className="text-ink">Pro ($9.99/month)</b>. Developers use the REST API with credits from <b className="text-ink">$0.05 per image</b>.
              <div className="mt-4 flex gap-2">
                <a href="/pricing" className="btn-primary btn-sm">
                  See pricing
                </a>
                <a href="/api" className="btn-secondary btn-sm">
                  API docs
                </a>
              </div>
            </div>
          </div>
        </section>
      </main>
      <Footer />
      {flow.cropDialog}
    </div>
  )
}
