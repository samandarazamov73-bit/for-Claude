import type { ImageInfo, JobState, VectorGraphJSON } from './types'

export class ApiError extends Error {
  status: number
  code: string | number
  constructor(status: number, code: string | number, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

const H = { 'X-Requested-With': 'vectorize' }

async function parseError(r: Response): Promise<ApiError> {
  try {
    const j = await r.json()
    if (j?.error) return new ApiError(r.status, j.error.code, j.error.message)
  } catch {
    /* not JSON */
  }
  return new ApiError(r.status, 'http_' + r.status, r.statusText || 'Request failed')
}

export async function api<T>(path: string, init: RequestInit & { json?: unknown } = {}): Promise<T> {
  const headers: Record<string, string> = { ...H, ...(init.headers as Record<string, string>) }
  let body = init.body
  if (init.json !== undefined) {
    headers['Content-Type'] = 'application/json'
    body = JSON.stringify(init.json)
  }
  let r: Response
  try {
    r = await fetch(path, { ...init, headers, body, credentials: 'same-origin' })
  } catch {
    throw new ApiError(0, 'network', 'Network error – check your connection.')
  }
  if (!r.ok) throw await parseError(r)
  const ct = r.headers.get('content-type') ?? ''
  return (ct.includes('application/json') ? r.json() : r.text()) as Promise<T>
}

export interface UploadResult {
  token: string
  jobId: string
  width: number
  height: number
  format: string
  filename: string
}

/** Multipart upload with real upload progress (XMLHttpRequest). */
export function uploadImage(
  file: Blob,
  filename: string,
  opts: { crop?: [number, number, number, number] | null; options?: object; onProgress?: (f: number) => void; signal?: AbortSignal },
): Promise<UploadResult> {
  return new Promise((resolve, reject) => {
    const fd = new FormData()
    fd.append('file', file, filename)
    if (opts.crop) fd.append('crop', JSON.stringify(opts.crop))
    if (opts.options) fd.append('options', JSON.stringify(opts.options))
    const xhr = new XMLHttpRequest()
    xhr.open('POST', '/api/images')
    xhr.setRequestHeader('X-Requested-With', 'vectorize')
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) opts.onProgress?.(e.loaded / e.total)
    }
    xhr.onload = () => {
      let j: any = null
      try {
        j = JSON.parse(xhr.responseText)
      } catch {
        /* ignore */
      }
      if (xhr.status >= 200 && xhr.status < 300) resolve(j)
      else reject(new ApiError(xhr.status, j?.error?.code ?? 'upload_failed', j?.error?.message ?? 'Upload failed'))
    }
    xhr.onerror = () => reject(new ApiError(0, 'network', 'Network error during upload.'))
    xhr.onabort = () => reject(new ApiError(0, 'aborted', 'Upload cancelled.'))
    opts.signal?.addEventListener('abort', () => xhr.abort())
    xhr.send(fd)
  })
}

export const getImage = (token: string) => api<ImageInfo>(`/api/images/${token}`)
export const getJob = (id: string) => api<JobState>(`/api/jobs/${id}`)

export async function getGraph(token: string): Promise<VectorGraphJSON> {
  return api<VectorGraphJSON>(`/api/images/${token}/graph`)
}

/** Live job progress via Server-Sent Events with polling fallback. */
export function watchJob(jobId: string, onUpdate: (j: JobState) => void): () => void {
  let closed = false
  let es: EventSource | null = null
  let timer: number | undefined
  const terminal = (s: string) => s === 'completed' || s === 'failed' || s === 'cancelled'
  const poll = async () => {
    if (closed) return
    try {
      const j = await getJob(jobId)
      onUpdate(j)
      if (terminal(j.status)) return
    } catch {
      /* transient */
    }
    timer = window.setTimeout(poll, 700)
  }
  if (typeof EventSource !== 'undefined') {
    es = new EventSource(`/api/jobs/${jobId}/events`)
    es.addEventListener('progress', (ev) => {
      const j = JSON.parse((ev as MessageEvent).data) as JobState
      onUpdate(j)
      if (terminal(j.status)) es?.close()
    })
    es.onerror = () => {
      es?.close()
      es = null
      if (!closed) poll()
    }
  } else poll()
  return () => {
    closed = true
    es?.close()
    if (timer) clearTimeout(timer)
  }
}

export async function downloadFile(url: string, fallbackName: string): Promise<void> {
  const r = await fetch(url, { credentials: 'same-origin' })
  if (!r.ok) throw await parseError(r)
  const blob = await r.blob()
  const cd = r.headers.get('content-disposition') ?? ''
  const m = /filename="([^"]+)"/.exec(cd)
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = m?.[1] ?? fallbackName
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(a.href), 5000)
}
