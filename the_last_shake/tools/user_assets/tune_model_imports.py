"""After Godot extracted the textures of sanatorium/models/*.glb (<model>_Image_N.jpg|png), make them
VRAM-compressed with a size limit, and mark the glTF normal maps as normal maps. Run, then import again.
Usage: python3 tune_model_imports.py <project root>"""
import sys, os, re, json, struct, glob

ROOT = sys.argv[1]
D = os.path.join(ROOT, "sanatorium/models")
BIG = {"prologue_bus_stop", "epi_bed", "epi_bed_2", "wardrobe", "story_washer", "story_kiosk"}   # 2048, the rest 1024

def gltf_json(path):
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    return json.loads(b[20:20 + n])

for glb in sorted(glob.glob(os.path.join(D, "*.glb"))):
    name = os.path.basename(glb)[:-4]
    j = gltf_json(glb)
    tex_img = {i: t.get("source") for i, t in enumerate(j.get("textures", []))}
    normals = set()
    for m in j.get("materials", []):
        nt = m.get("normalTexture")
        if nt is not None:
            normals.add(tex_img.get(nt["index"]))
    imgs = j.get("images", [])
    for k, im in enumerate(imgs):
        nm = im.get("name") or f"Image_{k}"
        for f in glob.glob(os.path.join(D, f"{name}_{nm}.*.import")):
            s = open(f).read()
            s = re.sub(r"compress/mode=\d", "compress/mode=2", s)
            s = re.sub(r"detect_3d/compress_to=\d", "detect_3d/compress_to=0", s)
            s = re.sub(r"process/size_limit=\d+", "process/size_limit=%d" % (2048 if name in BIG else 1024), s)
            s = re.sub(r"compress/normal_map=\d", "compress/normal_map=%d" % (1 if k in normals else 2), s)
            open(f, "w").write(s)
            print(os.path.basename(f), "normal" if k in normals else "")
