/// <reference lib="webworker" />
// Decodes an image off the main thread: returns its size and a downsampled
// preview bitmap (used by the Pre-Crop dialog for very large images).

self.onmessage = async (e: MessageEvent<{ file: Blob; maxSide: number }>) => {
  const { file, maxSide } = e.data
  try {
    const full = await createImageBitmap(file)
    const { width, height } = full
    const s = Math.min(1, maxSide / Math.max(width, height))
    let preview: ImageBitmap = full
    if (s < 1) {
      preview = await createImageBitmap(full, { resizeWidth: Math.max(1, Math.round(width * s)), resizeHeight: Math.max(1, Math.round(height * s)), resizeQuality: 'high' })
      full.close()
    }
    ;(self as unknown as Worker).postMessage({ ok: true, width, height, preview }, [preview])
  } catch (err) {
    ;(self as unknown as Worker).postMessage({ ok: false, error: String(err) })
  }
}
