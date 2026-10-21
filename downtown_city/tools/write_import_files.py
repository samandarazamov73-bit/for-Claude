"""Write Godot .import presets for every texture so they are imported as
VRAM-compressed textures with mipmaps (normal maps flagged as such).
Godot fills in the generated paths/uids on first import.

Usage: python3 tools/write_import_files.py <project_dir>
"""
import os
import sys

TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://textures/{name}"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/hdr_compression=1
compress/normal_map={normal}
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""

root = sys.argv[1] if len(sys.argv) > 1 else "."
tex = os.path.join(root, "textures")
for fn in sorted(os.listdir(tex)):
    if not fn.endswith(".png"):
        continue
    normal = 1 if fn.endswith("_Normal.png") else 0
    with open(os.path.join(tex, fn + ".import"), "w") as f:
        f.write(TEMPLATE.format(name=fn, normal=normal))
print("ok")
