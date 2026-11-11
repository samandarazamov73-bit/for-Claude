export type RGB = [number, number, number]

export function hexToRgb(hex: string): RGB {
  const h = hex.replace('#', '')
  const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h
  return [parseInt(full.slice(0, 2), 16), parseInt(full.slice(2, 4), 16), parseInt(full.slice(4, 6), 16)]
}

export const rgbToHex = (c: ArrayLike<number>) =>
  '#' + [c[0], c[1], c[2]].map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('')

function lin(v: number) {
  v /= 255
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
}

/** sRGB -> CIELAB (D65). */
export function rgbToLab([r, g, b]: RGB): [number, number, number] {
  const R = lin(r), G = lin(g), B = lin(b)
  let x = (R * 0.4124 + G * 0.3576 + B * 0.1805) / 0.95047
  let y = R * 0.2126 + G * 0.7152 + B * 0.0722
  let z = (R * 0.0193 + G * 0.1192 + B * 0.9505) / 1.08883
  const f = (t: number) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116)
  x = f(x); y = f(y); z = f(z)
  return [116 * y - 16, 500 * (x - y), 200 * (y - z)]
}

export function deltaE(a: RGB, b: RGB): number {
  const la = rgbToLab(a), lb = rgbToLab(b)
  return Math.hypot(la[0] - lb[0], la[1] - lb[1], la[2] - lb[2])
}

/** Relative luminance-based ink colour for text on a swatch. */
export const readableInk = (c: ArrayLike<number>) => (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2] > 150 ? '#111318' : '#ffffff')

/** Project points to their two principal components (weighted). */
export function pca2(points: number[][], weights?: number[]): [number, number][] {
  const n = points.length
  if (n === 0) return []
  const d = points[0].length
  const w = weights ?? points.map(() => 1)
  const ws = w.reduce((a, b) => a + b, 0) || 1
  const mean = new Array(d).fill(0)
  points.forEach((p, i) => p.forEach((v, k) => (mean[k] += (v * w[i]) / ws)))
  const cov = Array.from({ length: d }, () => new Array(d).fill(0))
  points.forEach((p, i) => {
    for (let a = 0; a < d; a++) for (let b = 0; b < d; b++) cov[a][b] += (w[i] * (p[a] - mean[a]) * (p[b] - mean[b])) / ws
  })
  const power = (m: number[][], deflate?: number[]) => {
    let v = new Array(d).fill(0).map((_, i) => 1 / Math.sqrt(d) + i * 1e-3)
    for (let it = 0; it < 60; it++) {
      let nv = m.map((row) => row.reduce((s, x, j) => s + x * v[j], 0))
      if (deflate) {
        const dot = nv.reduce((s, x, j) => s + x * deflate[j], 0)
        nv = nv.map((x, j) => x - dot * deflate[j])
      }
      const norm = Math.hypot(...nv) || 1
      v = nv.map((x) => x / norm)
    }
    return v
  }
  const e1 = power(cov)
  const e2 = power(cov, e1)
  return points.map((p) => {
    const c = p.map((v, k) => v - mean[k])
    return [c.reduce((s, x, k) => s + x * e1[k], 0), c.reduce((s, x, k) => s + x * e2[k], 0)]
  })
}
