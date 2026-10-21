# City plan (reconstructed from the trailer)

The reference video is the trailer of the Quaternius **Downtown City MegaKit** (93 s, 1280×720).
The geometry modules in `models/kit/` come from that same kit (repos `Makrondar/osoososos` and
`Makrondar/osoososos2`), so the buildings are assembled from the parts the trailer shows.

## What the video shows

| Time | Shot | What it gives us |
|------|------|------------------|
| 0–7 s | Kit overview on a grey floor | module set, street pieces, signs: *THE JADE GARDEN*, *Paul & Sons Bakery*, *PA SAVINGS BANK BUILDING*, *Carmine's Original Pizza* |
| 8 s | Close-up, PA Savings Bank | rusticated limestone, green awnings, triple windows, engraved name over the ground floor, birch in an iron tree guard |
| 9.5 s | Paul & Sons Bakery | red-brown brick, limestone window surrounds and quoins, limestone ground floor, green sign + awning, hedges in planters |
| 11–17 s | **Hero shot**: low camera at the corner looking up at The Jade Garden | corner building: dark metal ground floor, red-brick piers, black metal windows, lit glass top floor, fire escape and vertical red banner on the left face, red sign over the entrance |
| 18–26 s | Street level down the main avenue | 2 lanes, dashed centre line, white edge lines ~1.5 m from the curb, zebra crossing, yellow *STOP* and *ONLY ↑* paint, birches every ~9 m in iron guards, 5 m sidewalks of light square slabs, the avenue ends in a T-junction at a pale mansard building |
| 27–40 s | Interior walls / window shader demo | fake-room interiors behind every window, curtains, warm lights |
| 41–62 s | Top-down edit of an intersection and a building | four-way crossing, rounded sidewalk corners, kerbs, 2 m facade grid, 3 m storeys |
| 63–75 s | Night | lit rooms, lights varying per window |
| 76–90 s | Vertex wear painting, final pan up the avenue | soot/wear at the base of the facades, skyline of 8–15 storey buildings, limestone tower on the bank corner |

The visible city is small (a handful of blocks around one intersection, empty white void beyond).
As requested, the reconstruction keeps that core and extends it into a larger downtown grid.

## Coordinates

1 unit = 1 m. +X east, −Z north, +Y up. Sidewalk level y = 0, asphalt y = −0.15 (15 cm kerb).

* Avenues (north–south) at x = −216, −108, **0 (main avenue)**, 108, 216.
* Streets (east–west) at z = −264, −176, −88, **0 (hero cross street)**, 88.
* Every right-of-way is 22 m: 12 m carriageway + 2 × 5 m sidewalks.
* The main avenue stops at z = −264 (T-junction) so the street view ends on a building,
  as in the trailer (≈ 260 m vista).
* City footprint 580 × 480 m (35 blocks) plus a skyline ring of simplified buildings out to ~900 m.

```
           x=-216   x=-108     x=0      x=108    x=216
z=-264 ─────┼────────┼─────────┴─────────┼────────┼──────   (T: vista building at x=0)
            │        │         │         │        │
z=-176 ─────┼────────┼─────────┼─────────┼────────┼──────
            │        │         │         │        │
z=-88  ─────┼────────┼─────────┼─────────┼────────┼──────
            │        │  BANK ┌─┼─┐ JADE  │        │
z=0    ─────┼────────┼───────┤ ┼ ├───────┼────────┼──────   hero intersection (0,0)
            │        │       └─┼─┘       │        │
z=88   ─────┼────────┼─────────┼─────────┼────────┼──────
```

## Hero intersection (0, 0)

North-east block (x 11…97, z −77…−11):

| Lot | Footprint (x, z) | Building | Notes |
|-----|------------------|----------|-------|
| NE corner | 11…31.6, −27.3…−10.7 | **The Jade Garden** (kit prebuilt `Building_Large_2`, 28 m) | red sign over the entrance, banner + fire escape on the west face |
| W side | 11…33, −51.3…−27.3 | **Paul & Sons Bakery** tower: red brick, limestone trims, 12 floors + slate mansard | green sign and awning, red blade sign, hedges |
| NW corner | 11…31, −77…−53 | pale limestone, 9 floors, mansard | |
| S side | 32…46 | cream brick with red double windows, 10 floors, mansard | right of The Jade Garden in the hero shot |
| S side | 46…58 | slate-blue painted building, 8 floors | |
| S side | 58…84 | tall limestone tower, 14 floors | |

North-west block: **PA Savings Bank Building** (limestone, 14 floors, arched ground floor,
green awnings, engraved name) on the corner; *May's Salon & Beauty* walk-up with a stoop
(kit prebuilt `Building_Small_1`) on the avenue.

Everything else is generated per block with the facade grammars from the trailer
(`scripts/building_generator.gd`), 4–16 storeys, flat roofs with bulkheads/AC units/water tanks
or slate mansards with dormers.

## Street furniture

Birches every ~9 m on the main avenue and the hero street (60 % elsewhere) with square iron
guards; lamp posts at block ends; signal poles with street-name blades on two corners per
intersection; hydrants, trash cans, mail boxes, benches, manholes and kerb drains.
Road paint is procedural in the asphalt shader (edge lines, centre dashes, zebra crossings,
stop lines); *STOP* and *ONLY ↑* are decals as in the trailer. There are no cars or
pedestrians in the trailer, so none are placed.

## Limits of the reconstruction

* Only three of the kit's prebuilt buildings are in the provided repos; the other trailer
  buildings were rebuilt from the kit's wall/window/cornice/roof modules to match their look.
* The kit's textures (except concrete/asphalt) were not provided; brick, limestone, slate,
  trim sheets, paving, bark, leaves, road paint and signs are generated by `tools/gen_textures.py`.
* The trees of the trailer come from a separate kit (Stylized Nature MegaKit) and are
  rebuilt procedurally.
* Invisible sides of buildings are completed in the same style; blank party walls where a
  building is taller than its neighbour, simple windows on courtyard sides.
