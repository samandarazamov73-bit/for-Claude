# Forest Drive — a forest road environment for Godot 4.7

One continuous two-lane rural road (3.64 km closed loop) through a dense mixed forest of pine,
spruce, fir, birch, oak, alder and linden. Real geometry everywhere: procedural trees with root
flares and branch structure, photoscanned CC0 rocks / stumps / logs, terrain with sub-metre relief,
a modelled road with shoulders and ditches. No buildings, no other roads.

![Road](docs/shots/01_road_straight.jpg)

| | |
|---|---|
| ![](docs/shots/02_road_curve.jpg) | ![](docs/shots/03_driver_low.jpg) |
| Curve through mixed forest | Driver's eye height, tree shadows across the road |
| ![](docs/shots/04_roadside.jpg) | ![](docs/shots/07_aerial.jpg) |
| Roadside: shoulder, verge, young spruce | From above: one road, continuous forest |
| ![](docs/shots/05_forest_inside.jpg) | ![](docs/shots/06_canopy_up.jpg) |
| Inside the forest | Canopy over the road |
| ![](docs/shots/08_ground_detail.jpg) | ![](docs/shots/10_lod_debug.jpg) |
| Ground cover at the verge | F4 LOD view: red LOD0, green LOD1, blue LOD2 (stippled = cross-fade) |

These screenshots come from the game itself (`-- --shots`), but they were rendered on a machine
**without a GPU** (Mesa llvmpipe software Vulkan): the first five with the High preset at 1280×720,
the others with Medium at 800×450.
They show the content faithfully; a real GPU on High/Ultra adds TAA, finer shadows and volumetric
light shafts.

## Run it

1. Godot **4.7.2** (standard build, not .NET) — https://godotengine.org/download
2. Godot → Import → `forest_drive/project.godot`. The first import compresses the textures (BC7 for
   desktop + ASTC for Apple Silicon) and takes several minutes.
3. Open `scenes/main.tscn`: terrain, road and forest are built in the editor too (a preview driven by
   the editor camera; generated nodes are never saved into the scene). F5 to drive.

Renderer: Forward+ (Vulkan on Windows/Linux, Metal on macOS). For weak integrated GPUs there is a
Mobile-renderer build: the export preset **Windows Low-End (Mobile renderer)** (feature tag `lowend`),
or run any build with `--rendering-method mobile`. Effects the Mobile renderer lacks (SSAO, SSIL, SSR,
volumetric fog, FSR) are switched off automatically and the exposure is lifted slightly; all shaders
were verified to compile and render with the Mobile renderer.

## Controls

| | Keyboard | Gamepad |
|---|---|---|
| Throttle / brake & reverse | W / S, ↑ / ↓ | RT / LT |
| Steer | A / D, ← / → | left stick |
| Handbrake | Space | |
| Put the car back on the road | R | |
| Camera: chase → driver → autopilot → free | C or Tab | Y |
| Free camera | mouse + WASD, E / Q up / down, Shift fast | |
| Autopilot speed | + / − | |
| Graphics preset (Low / Medium / High / Ultra) | G | |
| 30 fps cap | L | |
| Road wetness | [ / ] | |
| Profiler overlay | F3 | |
| LOD view (red LOD0, green LOD1, blue LOD2, yellow ground cover; terrain tinted by grid size) | F4 | |
| Help | F1 | |

## Geometry budget and measured performance

### Unique geometry (what the environment owns) — 405 953 triangles

Every distinct mesh and every LOD level counted once (`PerfStats.allocated_budget`, checked by the tests):

| Category | Target | Built |
|---|---:|---:|
| Main terrain (shared grid meshes, all 5 LODs) | 35–50 k | 45 632 |
| Main road | 15–25 k | 19 680 |
| Large trees (14 variants × 3 LODs) | 180–220 k | 187 713 |
| Medium vegetation (11 understory variants × 3 LODs) | 65–85 k | 62 789 |
| Rocks and stones (11 scanned rocks × 3 LODs + stones) | 20–30 k | 29 380 |
| Bushes and plants (11 shrubs × 3 LODs, ferns, grass, forbs) | 35–45 k | 35 920 |
| Ground details (scanned stumps, log, branches; moss sprouts) | 10–15 k | 10 431 |
| Additional details (root clusters, branch piles, wind-thrown trees) | 15–25 k | 14 408 |
| **Total** | **400–500 k** | **405 953** |

LOD0 of a large tree is 8–15 k triangles (conifers: whorled branches + 700–1 600 needle-sprig cards;
broadleaves: 3-level branching + leaf-cluster cards), LOD1 1.3–2.6 k, LOD2 80–250.

### Per frame (what the GPU is asked to draw)

Because the 529 577 instances reuse those meshes, a frame submits several million triangles. Measured
with `-- --bench` driving the autopilot round the loop (averages over several points of the road,
960×540; triangle and draw-call counts do not depend on the GPU):

| | Low | Medium | High |
|---|---:|---:|---:|
| Triangles submitted, main pass | 2.27 M | 3.89 M | 5.51 M |
| Triangles submitted, shadow passes | 0.48 M | 0.93 M | 5.15 M |
| Draw calls main / shadow | 263 / 119 | 284 / 139 | 301 / 272 |
| Instances drawn LOD0 / LOD1 / LOD2 / ground cover | 85 / 453 / 4 206 / 871 | 142 / 751 / 6 763 / 2 217 | 184 / 1 059 / 10 114 / 4 019 |
| LOD + culling update (worker thread, every 4 m / 7°) | 18.7 ms | 25.6 ms | 33.9 ms |
| Video memory (Godot monitor) | 559 MB | 594 MB | 640 MB |
| of which textures | 367 MB | 401 MB | 444 MB |
| Static RAM (Godot) | 191 MB | 191 MB | 192 MB |
| Scene nodes | ~1 390 | ~1 390 | ~1 390 |

"Submitted" includes the instances that are inside a cross-fade band and are collapsed by the vertex
shader, so the rasterised count is somewhat lower. Ultra was not measured here (see below).

**Frame rate: not measured on real hardware.** The machine this was built on has no GPU; the only
renderer available was Mesa llvmpipe (software Vulkan on a 4-core Xeon), which needs 12–60 s per frame
for this scene, so those timings say nothing about a GPU and are not quoted as FPS. The Ultra preset
(8192² shadow atlas, MSAA) did not fit into that machine's memory under software rendering.
`.github/workflows/forest-drive.yml` benchmarks every preset on GitHub's Apple-Silicon runner
(`macos-15`, Metal) and uploads `bench.json` + screenshots as an artifact, and launches the Windows
build; run it to get real numbers, or on your own machine:

```
godot --path forest_drive -- --bench --all-presets --seconds=25 --out=bench
```


## How it is built

### Project layout

```
forest_drive/
  project.godot            Forward+, Metal on macOS, Jolt physics, shader globals
  scenes/main.tscn         sky, environment, sun, terrain/road/forest nodes, camera rig, HUD
  scripts/
    world.gd               loads the baked world, drives per-frame systems, input, presets
    terrain_generator.gd   chunked GPU terrain, LOD selection, collision, hill occluders
    road_builder.gd        road mesh from the baked centreline, collision, lane sampling
    forest_generator.gd    catalog + baked instance sets -> LodManager
    lod_manager.gd         per-instance LOD, distance/frustum/shadow culling and density for everything
                           instanced: trees, understory, bushes, rocks, props and ground cover
    graphics_settings.gd   LOW / MEDIUM / HIGH / ULTRA presets (autoload)
    vehicle.gd, camera_rig.gd, hud.gd, perf_stats.gd
  shaders/                 terrain, road, bark, foliage, rock + shared include
  assets/
    trees/ vegetation/ rocks/ props/   .glb meshes, nodes LOD0..LOD2
    textures/              packed texture arrays and atlases (WebP sources, VRAM-compressed on import)
    materials/             the 7 shared ShaderMaterials
    catalog.json           every variant: size, clearance, LOD distances, triangle counts
  resources/world/         heightmap, control maps, road centreline, baked instance buffers
  tests/test_runner.gd     automated checks, screenshots, benchmark
  tools/                   Python pipeline that produced assets/ and resources/ (ignored by Godot)
```

### Terrain
* 2 × 2 km, 1 m heightmap (2049²), relief ≈ 48 m: large hills, 20–100 m undulations and hummocks;
  the road corridor is carved in: asphalt bed, gravel shoulder, ditch, berm and cut/fill embankments
  whose width follows the height difference.
* 1024 chunks of 64 m share five grid meshes (0.5 / 1 / 2 / 4 / 8 m). The vertex shader displaces them
  from the heightmap, adds ±8 cm forest-floor relief near the camera, and morphs odd vertices onto
  the coarser grid before each switch (CDLOD-style), so LOD changes do not pop. Skirts hide the
  remaining T-junctions (the test measures every chunk border against the skirt depth).
* Six material layers (broadleaf litter, pine needles, moss, grass, soil, gravel) from two control maps,
  height-blended, two rotated samples per layer against tiling, macro colour variation, a macro normal
  map, canopy-based ambient occlusion and wet ditches.
* Collision: `HeightMapShape3D`; occlusion: a conservative low-resolution hill occluder.

### Road
* Closed loop, 3.64 km: long north straight, S-bends, a long south straight and a chicane; 37 % of the
  loop is straight (radius > 800 m), the tightest bend (the chicane) has a 66 m radius; grades up to 6 %.
* Cross-section: two 3.4 m lanes + 0.7 m paved strip, 2 % crown, 4 cm asphalt edge, gravel shoulder to
  5 m, skirt into the ditch. Sections every 1.25–3.5 m depending on curvature (~20 k triangles).
* The road shader works in road space: two scanned asphalts (clean, and old asphalt with transverse
  cracks), repair patches with sealed seams, sealed longitudinal/transverse cracks, polished wheel
  paths and an oil line, worn paint (double yellow centre + white edges like the reference, or a
  European dashed centre: `marking_style` on the World node), crumbling edges into the gravel, dirt and
  fallen leaves at the edges, damp asphalt and puddles in the ruts (`wetness`, [ ] keys).

### Forest
* 14 large tree variants (3 Scots pine, 3 Norway spruce, 2 silver fir, 2 silver birch, 2 oak, alder,
  linden), 11 understory variants (young spruce/fir/pine/birch/alder/oak, rowan, hazel, standing dead
  snag), 11 bushes and low shrubs (incl. bilberry and juniper), 18 ground-cover variants (grass, ferns,
  nettle, cow parsley, moss sprouts, stones, twigs), 11 photoscanned rocks, scanned stumps / log /
  branches and procedural root clusters, branch piles and wind-thrown trees.
* Trees are generated (`tools/build_assets.py`): irregular trunks with buttressed root flares and
  exposed roots, whorled conifer branches with drooping sprig cards, pine limbs with needle tufts,
  recursive deciduous branching inside crown envelopes, crown-shaped normals, baked AO and wind
  weights. All foliage uses one 4K atlas of CC0 scanned sprigs / leaves; all bark one texture array.
* Placement (`tools/world_gen.py`): species follow moisture, slope and noise fields (pine on dry
  ridges, spruce in hollows, birch along the edges and clearings, oak on sunny slopes), Poisson-style
  spacing, natural clearings, a denser edge wall along the road, understory in light gaps, bushes at the
  forest edge, ferns and grass along the verge. 117 k trees, 34 k understory, 25 k bushes, 3 k rocks,
  5 k props, 346 k ground-cover plants.

### Level of detail and culling
* **One system for every instance** (529 577 of them): trees, understory, bushes, rocks and props have
  three LOD meshes, ground cover one. Instances are baked into MultiMesh buffers per 32 m cell.
  `LodManager` rebuilds one `MultiMeshInstance3D` bucket per variant and LOD on a worker thread every
  4 m / 7° of camera movement: cells outside the band are skipped, then every instance is tested
  against its exact distance band and a widened view frustum (instances that can throw a shadow into
  the view are kept), and ground cover is thinned by the preset density. The vertex shader then
  makes the final per-instance decision with the distance to the main camera and cross-fades LOD n
  into n+1 with complementary dither masks, so there is no popping and the shadow pass picks the same
  LOD. Ground cover fades by dithering and sinking into the floor. Draw calls stay at
  variants × LODs × surfaces however many instances exist; the whole scene has ~1 390 nodes.
* **Terrain**: per-chunk LOD + Godot frustum culling with per-chunk AABBs + hill occluders.
* **Shadows**: a bucket's bounding box surrounds the camera, so every shadow cascade would render
  every casting bucket; the casters are therefore cut on the CPU: LOD1 plants beyond 75 % of the
  shadow distance go to a separate bucket that never casts (the canopy map shades the ground and trees
  out there instead), LOD2 never casts, grass/ferns don't cast (except ferns on Ultra), the finest
  terrain chunks don't cast on Low/Medium, and on Low/Medium the shadow pass draws nearby plants with
  their LOD1 mesh. High uses two cascades, Ultra four.
* **Draw calls / materials**: 7 shared materials, texture arrays and atlases instead of per-asset
  textures; VRAM-compressed textures (BC7 on desktop, ASTC for Apple Silicon builds) with mipmaps.

### Lighting and atmosphere
Directional sun (PCSS-soft on High/Ultra) shining through real alpha-tested foliage shadows, sky
ambient + SSAO + SSIL, AgX tone mapping, exponential fog with aerial perspective, low mist in hollows,
volumetric fog for light shafts on High/Ultra, subtle glow, canopy-density ambient occlusion and
translucent leaves.

## Graphics presets

Picked automatically on first launch from the GPU name (Intel UHD/HD → Low, Apple M-series base /
Intel Iris Xe / AMD integrated → Medium, Apple Pro/Max, NVIDIA, AMD RX → High), then **G** cycles and
the choice is saved in `user://graphics.cfg`. `--quality=low|medium|high|ultra` overrides it.

| | Low | Medium | High | Ultra |
|---|---|---|---|---|
| 3D resolution | 75 % + FSR 1 | 85 % + FSR 1 | 100 % | 100 % |
| Anti-aliasing | FXAA | FXAA | TAA | TAA + MSAA 2× |
| Tree LOD distances (LOD0 / LOD1 / far end, m) | 24 / 72 / 260 | 32 / 96 / 336 | 40 / 120 / 420 | 54 / 162 / 590 |
| Ground cover distance, density | 55 %, 45 % | 80 %, 75 % | 100 % | 140 % |
| Sun shadows | 2048², 60 m, 2 cascades | 4096², 90 m, 2 cascades | 4096², 110 m, 2 cascades, PCSS | 8192², 190 m, 4 cascades, PCSS |
| Shadows of nearby plants | from LOD1 mesh | from LOD1 mesh | full detail | full detail (+ ferns) |
| SSAO / SSIL / SSR | – / – / – | ✓ / – / – | ✓ / ✓ / – | ✓ / ✓ / ✓ |
| Volumetric fog (light shafts) | – | – | ✓ | ✓ (finer froxels) |
| Terrain detail / anti-tiling | 65 % / off | 85 % / on | 100 % / on | 130 % / on |
| Far plane | 650 m | 900 m | 1200 m | 1500 m |


## Rebuilding the content

Everything in `assets/` and `resources/world/` is generated:

```
python3 tools/fetch_assets.py      # downloads the CC0 sources into tools/.cache (≈ 400 MB)
python3 tools/build_textures.py    # packs texture arrays / atlases
python3 tools/build_assets.py      # trees, plants, scans -> .glb with LODs + catalog.json
python3 tools/world_gen.py         # road, terrain, masks, placement
```
(Python 3.11+, numpy, scipy, pillow, meshoptimizer.)

## Quality control

`godot --headless --path forest_drive -- --test` runs 27 checks (all pass):

* every mesh in the catalog exists and has its LODs with the shared shader materials; every material
  sampler has a texture; ≥ 12 tree variants with three decreasing LODs;
* heightmap and 1024 chunks load; relief > 20 m; the road centreline is continuous and closed,
  grades ≤ 8 %; the terrain never pokes through the asphalt (18 200 samples across the width);
* **no floating objects and no buried trees/props** (all 183 827 instances checked against the
  terrain), **nothing standing on the road or shoulders** (trees ≥ 6.6 m from the centreline, rocks
  ≥ 6.9 m, logs ≥ 8 m), ground cover off the asphalt; long logs are only placed where they rest on the
  ground along their whole length;
* terrain LOD seams: the worst height gap at every LOD border is measured and must be covered by the
  skirt of that level;
* the unique-triangle budget is inside 400–500 k;
* LOD buckets are filled, LOD0 buckets only contain nearby cells, culling re-runs when the camera turns,
  the scene stays under 2 500 nodes;
* all four presets apply; the car accelerates, drives along the road, stays on the surface and steers
  the right way.

Other modes:

```
godot --path forest_drive -- --shots --out=<dir> [--quality=high] [--only=01,04] [--settle=4]
godot --path forest_drive -- --bench --all-presets --seconds=25 --out=<dir>
```
F4 in the game shows the LOD levels (screenshot `docs/shots/10_lod_debug.jpg`).

## Licences

All third-party content is CC0 (public domain):
* Poly Haven (polyhaven.com): textures forest_leaves_03, forest_leaves_04, sparse_grass, mud_forest,
  rock_ground, clean_asphalt, asphalt_02, pine_bark, bark_brown_02, tree_bark_03; foliage textures of
  fir_tree_01, pine_tree_01, fern_02, grass_medium_01, moss_01, nettle_plant; models rock_moss_set_01,
  rock_moss_set_02, boulder_01, stone_01, tree_stump_01, tree_stump_02, dead_tree_trunk,
  dry_branches_medium_01.
* ambientCG (ambientcg.com): Moss002, Bark014, Bark001, Leaf001, Leaf003.

The birch bark, all tree / plant geometry, the terrain and the road are generated by the scripts in
`tools/` and belong to this project.
