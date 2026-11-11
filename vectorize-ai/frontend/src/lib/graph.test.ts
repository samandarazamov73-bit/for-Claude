import { describe, expect, it } from 'vitest'
import { deriveRenderState, interfaceCmds, resolveColor } from './graph'
import { pca2, rgbToLab, hexToRgb, rgbToHex } from './color'
import { emptyEdits, type VectorGraphJSON } from './types'

describe('interfaceCmds', () => {
  it('reverses lines, curves and arcs consistently', () => {
    const c = interfaceCmds([0, 0], [
      ['L', 10, 0],
      ['C', 12, 0, 14, 2, 14, 4],
      ['A', 14, 10, 6, -Math.PI / 2, Math.PI / 2],
    ])
    expect(c.end[0]).toBeCloseTo(20)
    expect(c.end[1]).toBeCloseTo(10)
    expect(c.rev[0]).toMatchObject({ t: 'A', ccw: true })
    const back = c.rev[1] as { t: string; c1x: number; c2x: number; x: number; y: number }
    expect(back).toMatchObject({ t: 'C', c1x: 14, c2x: 12, x: 10, y: 0 })
    expect(c.rev[2]).toMatchObject({ t: 'L', x: 0, y: 0 })
  })
})

const graph: VectorGraphJSON = {
  version: 1,
  width: 10,
  height: 10,
  scale: 1,
  original: [10, 10],
  palette: [
    { rgba: [255, 255, 255, 255], hex: '#ffffff', count: 60 },
    { rgba: [0, 0, 255, 255], hex: '#0000ff', count: 30 },
    { rgba: [255, 0, 0, 255], hex: '#ff0000', count: 10 },
  ],
  nodes: [],
  interfaces: [],
  shapes: [
    { id: 0, color: 0, transparent: false, loops: [[], []], area: 60, bbox: [0, 0, 10, 10], parent: -1, parentHole: -1, depth: 0, stackHoles: [] },
    { id: 1, color: 1, transparent: false, loops: [[], []], area: 30, bbox: [2, 2, 8, 8], parent: 0, parentHole: 1, depth: 1, stackHoles: [] },
    { id: 2, color: 2, transparent: false, loops: [[]], area: 10, bbox: [4, 4, 6, 6], parent: 1, parentHole: 1, depth: 2, stackHoles: [] },
  ],
  order: [0, 1, 2],
  stats: {} as never,
}

describe('deriveRenderState', () => {
  it('fills holes unless something transparent is inside', () => {
    const rs = deriveRenderState(graph, emptyEdits())
    expect(rs.holes[0]).toEqual([])
    expect(rs.holes[1]).toEqual([])
    const hidden = deriveRenderState(graph, { ...emptyEdits(), hiddenShapes: [2] })
    expect(hidden.fill[2]).toBeUndefined()
    expect(hidden.holes[1]).toEqual([1]) // the hole must stay open now
    expect(hidden.holes[0]).toEqual([1]) // and the outer shape's hole too
  })
  it('keeps gradients unless the shape is recoloured', () => {
    const g2 = { ...graph, shapes: graph.shapes.map((s) => (s.id === 1 ? { ...s, fill: { type: 'linear' as const, x1: 0, y1: 0, x2: 10, y2: 0, stops: [[0, 0, 0, 0, 255], [1, 255, 255, 255, 255]] } } : s)) }
    expect(deriveRenderState(g2, emptyEdits()).paints[1]).toBeDefined()
    expect(deriveRenderState(g2, { ...emptyEdits(), shapeColors: { '1': 2 } }).paints[1]).toBeUndefined()
  })
  it('applies recolours, merges and deletions', () => {
    const e = { ...emptyEdits(), paletteOverrides: { '1': [0, 128, 0, 255] as [number, number, number, number] }, mergedColors: { '2': 1 }, deletedColors: [0] }
    const rs = deriveRenderState(graph, e)
    expect(rs.fill[0]).toBeUndefined()
    expect(rs.fill[1]).toBe('rgb(0,128,0)')
    expect(rs.fill[2]).toBe('rgb(0,128,0)')
    expect(resolveColor(2, { '2': 1, '1': 0 })).toBe(0)
  })
})

describe('color utils', () => {
  it('converts colours and projects palettes', () => {
    expect(rgbToHex(hexToRgb('#3d5afe'))).toBe('#3d5afe')
    const lab = rgbToLab([255, 255, 255])
    expect(lab[0]).toBeCloseTo(100, 0)
    const p = pca2([[0, 0, 0], [10, 0, 0], [20, 0, 0]])
    expect(Math.abs(p[2][0] - p[0][0])).toBeCloseTo(20, 3)
  })
})
