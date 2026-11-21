"""Blender (bpy): re-save every glb with its textures at 1024 px (big items 2048) as JPEG — the game uses
them at that size anyway, and the files get several times smaller.
python -c "import sys; sys.argv=['x','<in dir>','<out dir>']; exec(open('shrink_models.py').read())" """
import bpy, sys, os
SRC, OUT = sys.argv[-2], sys.argv[-1]
BIG = {"prologue_bus_stop", "epi_bed", "epi_bed_2", "wardrobe", "story_washer", "story_kiosk"}
os.makedirs(OUT, exist_ok=True)
for f in sorted(os.listdir(SRC)):
    if not f.endswith(".glb"):
        continue
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, f))
    lim = 2048 if f[:-4] in BIG else 1024
    for im in bpy.data.images:
        w, h = im.size
        if max(w, h) > lim:
            k = lim / max(w, h)
            im.scale(max(4, int(w * k)), max(4, int(h * k)))
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, f), export_format="GLB", use_selection=False,
                              export_image_format="JPEG", export_jpeg_quality=90, export_yup=True)
    print("shrunk", f, os.path.getsize(os.path.join(OUT, f)) // 1024, "KB")
