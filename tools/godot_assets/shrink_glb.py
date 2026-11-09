"""Пережимает картинки внутри GLB (JPEG, не больше 1024 px; PNG с прозрачностью остаётся PNG)
и печатает габариты модели. Запуск: python3 shrink_glb.py in.glb out.glb"""
import io, json, struct, sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
b = open(src, "rb").read()
ln, = struct.unpack_from("<I", b, 12)
js = json.loads(b[20:20 + ln])
o = 20 + ln
bl, = struct.unpack_from("<I", b, o)
bin_ = b[o + 8:o + 8 + bl]
img_view = {im["bufferView"]: im for im in js.get("images", []) if "bufferView" in im}
out = bytearray()
for vi, v in enumerate(js["bufferViews"]):
    data = bin_[v.get("byteOffset", 0):v.get("byteOffset", 0) + v["byteLength"]]
    if vi in img_view:
        im = Image.open(io.BytesIO(data))
        alpha = im.mode in ("RGBA", "LA") and im.getchannel("A").getextrema()[0] < 250
        im = im.convert("RGBA" if alpha else "RGB")
        if max(im.size) > 1024:
            k = 1024 / max(im.size)
            im = im.resize((max(1, int(im.size[0] * k)), max(1, int(im.size[1] * k))), Image.LANCZOS)
        bio = io.BytesIO()
        if alpha:
            im.save(bio, "PNG", optimize=True)
            img_view[vi]["mimeType"] = "image/png"
        else:
            im.save(bio, "JPEG", quality=88)
            img_view[vi]["mimeType"] = "image/jpeg"
        data = bio.getvalue()
    while len(out) % 4:
        out += b"\0"
    v["byteOffset"] = len(out)
    v["byteLength"] = len(data)
    v["buffer"] = 0
    out += data
while len(out) % 4:
    out += b"\0"
js["buffers"] = [{"byteLength": len(out)}]
lo = [1e9] * 3
hi = [-1e9] * 3
for m in js["meshes"]:
    for p in m["primitives"]:
        a = js["accessors"][p["attributes"]["POSITION"]]
        lo = [min(x, y) for x, y in zip(lo, a["min"])]
        hi = [max(x, y) for x, y in zip(hi, a["max"])]
jb = json.dumps(js, separators=(",", ":")).encode()
while len(jb) % 4:
    jb += b" "
total = 12 + 8 + len(jb) + 8 + len(out)
with open(dst, "wb") as f:
    f.write(struct.pack("<4sII", b"glTF", 2, total))
    f.write(struct.pack("<II", len(jb), 0x4E4F534A) + jb)
    f.write(struct.pack("<II", len(out), 0x004E4942) + bytes(out))
print("%s %d KB  min %s max %s (mesh space, без учёта узлов)" % (dst.split("/")[-1], total // 1024,
      [round(x, 3) for x in lo], [round(x, 3) for x in hi]))
