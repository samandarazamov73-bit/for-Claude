import { useEffect, useRef, useState } from 'react'
import { ArrowRight, ImageUp, Link2 } from 'lucide-react'
import { ACCEPT } from '../lib/probe'

interface Props {
  onFile: (f: File) => void
  onUrl: (url: string) => void
  busy?: boolean
}

export function UploadZone({ onFile, onUrl, busy }: Props) {
  const input = useRef<HTMLInputElement>(null)
  const [over, setOver] = useState(false)
  const [url, setUrl] = useState('')
  const depth = useRef(0)

  // Ctrl+V anywhere on the page
  useEffect(() => {
    const onPaste = (e: ClipboardEvent) => {
      if (busy) return
      const target = e.target as HTMLElement | null
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) return
      const items = Array.from(e.clipboardData?.items ?? [])
      const img = items.find((i) => i.kind === 'file' && i.type.startsWith('image/'))
      const file = img?.getAsFile()
      if (file) {
        e.preventDefault()
        onFile(new File([file], file.name && file.name !== 'image.png' ? file.name : `pasted-${Date.now()}.png`, { type: file.type }))
        return
      }
      const text = e.clipboardData?.getData('text/plain')?.trim()
      if (text && /^https?:\/\/\S+$/i.test(text)) {
        e.preventDefault()
        onUrl(text)
      }
    }
    window.addEventListener('paste', onPaste)
    return () => window.removeEventListener('paste', onPaste)
  }, [onFile, onUrl, busy])

  const pick = (files: FileList | null | undefined) => {
    const f = files?.[0]
    if (f) onFile(f)
  }

  return (
    <div className="w-full">
      <div
        className={`group relative flex min-h-[300px] cursor-pointer flex-col items-center justify-center rounded-2xl border-[1.5px] border-dashed px-6 py-12 text-center transition-colors sm:min-h-[340px] ${over ? 'border-accent bg-accent-soft/60' : 'border-line-strong bg-white hover:border-faint'} ${busy ? 'pointer-events-none opacity-60' : ''}`}
        onClick={() => input.current?.click()}
        onDragEnter={(e) => {
          e.preventDefault()
          depth.current++
          setOver(true)
        }}
        onDragOver={(e) => e.preventDefault()}
        onDragLeave={() => {
          depth.current = Math.max(0, depth.current - 1)
          if (depth.current === 0) setOver(false)
        }}
        onDrop={(e) => {
          e.preventDefault()
          depth.current = 0
          setOver(false)
          if (e.dataTransfer.files?.length) pick(e.dataTransfer.files)
          else {
            const u = e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain')
            if (u && /^https?:\/\//i.test(u.trim())) onUrl(u.trim())
          }
        }}
        role="button"
        tabIndex={0}
        aria-label="Upload an image"
        onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && input.current?.click()}
      >
        <div className="mb-5 flex size-14 items-center justify-center rounded-2xl border border-line bg-canvas text-ink-2 shadow-card transition-transform group-hover:-translate-y-0.5">
          <ImageUp className="size-6" strokeWidth={1.6} />
        </div>
        <div className="text-lg font-semibold tracking-tight sm:text-xl">Drop an image to vectorize</div>
        <p className="mt-1.5 text-sm text-muted">
          or <span className="font-medium text-accent">browse files</span> · paste with <span className="kbd">Ctrl</span> <span className="kbd">V</span>
        </p>
        <button type="button" className="btn-primary mt-6 h-10 px-5" onClick={(e) => { e.stopPropagation(); input.current?.click() }}>
          Browse files
        </button>
        <p className="mt-5 text-xs text-faint">PNG · JPEG · GIF · BMP · WebP · TIFF — up to 30 MB, transparency supported</p>
        <input ref={input} type="file" accept={ACCEPT} className="hidden" onChange={(e) => { pick(e.target.files); e.target.value = '' }} />
      </div>
      <form
        className="mt-3 flex gap-2"
        onSubmit={(e) => {
          e.preventDefault()
          if (url.trim()) onUrl(url.trim())
        }}
      >
        <div className="relative flex-1">
          <Link2 className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-faint" />
          <input className="input h-10 pl-9" type="url" inputMode="url" placeholder="…or paste an image URL" value={url} onChange={(e) => setUrl(e.target.value)} aria-label="Image URL" />
        </div>
        <button className="btn-secondary h-10" disabled={!url.trim() || busy}>
          Import <ArrowRight className="size-4" />
        </button>
      </form>
    </div>
  )
}
