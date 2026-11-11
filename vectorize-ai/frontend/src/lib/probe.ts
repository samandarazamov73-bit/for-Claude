export const MAX_FILE_BYTES = 30 * 1024 * 1024
export const MAX_WORKING_PIXELS = 3_145_828
export const MAX_UPLOAD_PIXELS = 33_554_432
export const ACCEPT = 'image/png,image/jpeg,image/gif,image/bmp,image/webp,image/tiff,.png,.jpg,.jpeg,.gif,.bmp,.webp,.tif,.tiff'

export interface Probe {
  width: number
  height: number
  preview: ImageBitmap
}

/** Decode in a worker; resolves null when the browser cannot decode the
 * format (e.g. TIFF outside Safari) – the server handles those. */
export function probeImage(file: Blob, maxSide = 1400): Promise<Probe | null> {
  return new Promise((resolve) => {
    let w: Worker
    try {
      w = new Worker(new URL('../workers/probe.worker.ts', import.meta.url), { type: 'module' })
    } catch {
      resolve(null)
      return
    }
    const timer = setTimeout(() => {
      w.terminate()
      resolve(null)
    }, 20000)
    w.onmessage = (e) => {
      clearTimeout(timer)
      w.terminate()
      resolve(e.data.ok ? { width: e.data.width, height: e.data.height, preview: e.data.preview } : null)
    }
    w.onerror = () => {
      clearTimeout(timer)
      w.terminate()
      resolve(null)
    }
    w.postMessage({ file, maxSide })
  })
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}

export const formatInt = (n: number) => n.toLocaleString('en-US')
