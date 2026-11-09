"""Склеивает анимации персонажа из нескольких GLB (по одной анимации в файле) в один GLB.

Модель, скелет и текстура берутся из первого файла, анимации — из всех, по именам костей.
Корневое движение убирается (кость Hips остаётся на месте по X/Z), кроме анимаций из KEEP_ROOT —
там смещение начинается от центра. Каналы масштаба выбрасываются. Текстура пережимается в JPEG.
Запуск: python3 merge_chars.py out.glb base.glb src1.glb:Имя_в_файле:новое_имя [src2.glb:...:...]
       («Имя_в_файле» можно оставить пустым — тогда первая анимация файла).
       новое_имя с окончанием «+root» сохраняет корневое движение (например fall+root).
       новое_имя с окончанием «@секунда» — спокойная стойка: поза из этого кадра замирает, остаётся только
       дыхание (грудь чуть поднимается, 4 с на вдох-выдох) и еле заметное покачивание (например idle_loop@0).
"""
import io, json, struct, sys
import numpy as np
from PIL import Image

COMP = {5126: (np.float32, 4), 5123: (np.uint16, 2), 5125: (np.uint32, 4), 5121: (np.uint8, 1)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
TEX_SIZE = 1024
STAND_LEN = 8.0          # длина спокойной стойки (с): 2 вдоха и 1 покачивание — без шва на стыке
STAND_STEP = 0.1
# (кость, ось в своих координатах, амплитуда в градусах, период в секундах)
BREATH = [("mixamorig:Spine", (1, 0, 0), 0.35, 4.0), ("mixamorig:Spine1", (1, 0, 0), 0.5, 4.0),
          ("mixamorig:Spine2", (1, 0, 0), 0.7, 4.0), ("mixamorig:Spine", (0, 0, 1), 0.45, 8.0)]
# в стойке шея и голова — прямо (как в позе покоя модели); куда смотреть, решает игра (bone_look.gd)
STRAIGHT = ("mixamorig:Neck", "mixamorig:Head")


def qmul(a, b):
    x1, y1, z1, w1 = a
    x2, y2, z2, w2 = b
    return np.array([w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2, w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
                     w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2, w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2], dtype=np.float32)


def sample(t, v, at, rot):
    """Значение канала в момент at (линейно; для поворотов — нормированная интерполяция по короткой дуге)."""
    t = t[:, 0]
    if at <= t[0]:
        return v[0].copy()
    if at >= t[-1]:
        return v[-1].copy()
    i = int(np.searchsorted(t, at)) - 1
    k = (at - t[i]) / max(t[i + 1] - t[i], 1e-6)
    a, b = v[i], v[i + 1]
    if rot and float(np.dot(a, b)) < 0.0:
        b = -b
    r = a * (1 - k) + b * k
    return r / np.linalg.norm(r) if rot else r


def load(path):
    b = open(path, "rb").read()
    ln, = struct.unpack_from("<I", b, 12)
    js = json.loads(b[20:20 + ln])
    off = 20 + ln
    bl, = struct.unpack_from("<I", b, off)
    return js, b[off + 8: off + 8 + bl]


def view_bytes(js, bin_, vi):
    v = js["bufferViews"][vi]
    o = v.get("byteOffset", 0)
    return bin_[o:o + v["byteLength"]]


def acc_array(js, bin_, ai):
    a = js["accessors"][ai]
    dt, size = COMP[a["componentType"]]
    n = NCOMP[a["type"]]
    v = js["bufferViews"][a["bufferView"]]
    o = v.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = v.get("byteStride", 0)
    if stride and stride != size * n:
        raw = np.frombuffer(bin_, dtype=np.uint8, count=stride * a["count"], offset=o).reshape(a["count"], stride)
        return np.frombuffer(raw[:, :size * n].tobytes(), dtype=dt).reshape(a["count"], n).copy()
    return np.frombuffer(bin_, dtype=dt, count=a["count"] * n, offset=o).reshape(a["count"], n).copy()


class Writer:
    def __init__(self):
        self.buf = bytearray()
        self.views = []
        self.accs = []

    def add_view(self, data, target=None, stride=None):
        while len(self.buf) % 4:
            self.buf += b"\0"
        v = {"buffer": 0, "byteOffset": len(self.buf), "byteLength": len(data)}
        if target:
            v["target"] = target
        if stride:
            v["byteStride"] = stride
        self.buf += data
        self.views.append(v)
        return len(self.views) - 1

    def add_acc(self, arr, typ, minmax=False):
        arr = np.ascontiguousarray(arr, dtype=np.float32)
        vi = self.add_view(arr.tobytes())
        a = {"bufferView": vi, "componentType": 5126, "count": int(arr.shape[0]), "type": typ}
        if minmax:
            a["min"] = [float(x) for x in arr.min(axis=0)]
            a["max"] = [float(x) for x in arr.max(axis=0)]
        self.accs.append(a)
        return len(self.accs) - 1


def main():
    out, base = sys.argv[1], sys.argv[2]
    specs = sys.argv[3:]
    js, bin_ = load(base)
    w = Writer()
    # 1) all base buffer views copied (the image one re-encoded), keeping indices
    img_views = {im["bufferView"]: i for i, im in enumerate(js.get("images", []))}
    anim_views = set()
    for a in js.get("animations", []):
        for s in a["samplers"]:
            anim_views.add(js["accessors"][s["input"]]["bufferView"])
            anim_views.add(js["accessors"][s["output"]]["bufferView"])
    view_map = {}
    for vi, v in enumerate(js["bufferViews"]):
        if vi in anim_views:
            continue
        data = view_bytes(js, bin_, vi)
        if vi in img_views:
            im = Image.open(io.BytesIO(data)).convert("RGB")
            if max(im.size) > TEX_SIZE:
                im = im.resize((TEX_SIZE, TEX_SIZE * im.size[1] // im.size[0]), Image.LANCZOS)
            bio = io.BytesIO()
            im.save(bio, "JPEG", quality=88)
            data = bio.getvalue()
            js["images"][img_views[vi]]["mimeType"] = "image/jpeg"
        nv = w.add_view(data, v.get("target"), v.get("byteStride"))
        view_map[vi] = nv
    acc_map = {}
    for ai, a in enumerate(js["accessors"]):
        if a.get("bufferView") in anim_views:
            continue
        na = dict(a)
        na["bufferView"] = view_map[a["bufferView"]]
        w.accs.append(na)
        acc_map[ai] = len(w.accs) - 1
    for im in js.get("images", []):
        im["bufferView"] = view_map[im["bufferView"]]
    for m in js["meshes"]:
        for p in m["primitives"]:
            p["attributes"] = {k: acc_map[v] for k, v in p["attributes"].items()}
            if "indices" in p:
                p["indices"] = acc_map[p["indices"]]
            for t in p.get("targets", []):
                for k in t:
                    t[k] = acc_map[t[k]]
    for s in js.get("skins", []):
        s["inverseBindMatrices"] = acc_map[s["inverseBindMatrices"]]
    names = {n.get("name", ""): i for i, n in enumerate(js["nodes"])}
    hips_rest = np.array(js["nodes"][names["mixamorig:Hips"]].get("translation", [0, 0, 0]), dtype=np.float32)
    # 2) animations from every source, by bone name
    anims = []
    for spec in specs:
        path, src_name, new_name = spec.split(":")
        freeze = None
        if "@" in new_name:
            new_name, at = new_name.split("@")
            freeze = float(at)
        keep_root = new_name.endswith("+root")
        new_name = new_name.replace("+root", "")
        sjs, sbin = (js, bin_) if path == base else load(path)
        cand = [a for a in sjs["animations"] if not src_name or a.get("name") == src_name]
        if not cand:
            raise SystemExit("no animation %s in %s" % (src_name, path))
        a = cand[0]
        snames = [n.get("name", "") for n in sjs["nodes"]]
        channels, samplers = [], []
        length = 0.0
        for c in a["channels"]:
            nm = snames[c["target"]["node"]]
            p = c["target"]["path"]
            if p == "scale" or nm not in names:
                continue
            s = a["samplers"][c["sampler"]]
            t = acc_array(sjs, sbin, s["input"])
            v = acc_array(sjs, sbin, s["output"])
            length = max(length, float(t.max()))
            if nm == "mixamorig:Hips" and p == "translation":
                if keep_root:
                    v[:, 0] = v[:, 0] - v[0, 0] + hips_rest[0]
                    v[:, 2] = v[:, 2] - v[0, 2] + hips_rest[2]
                else:
                    v[:, 0] = hips_rest[0]
                    v[:, 2] = hips_rest[2]
            if freeze is not None:
                rot = p == "rotation"
                base_v = sample(t, v, freeze, rot)
                if rot and nm in STRAIGHT:
                    base_v = np.array(js["nodes"][names[nm]].get("rotation", [0, 0, 0, 1]), dtype=np.float32)
                t = np.arange(0.0, STAND_LEN + 1e-6, STAND_STEP, dtype=np.float32).reshape(-1, 1)
                v = np.repeat(base_v.reshape(1, -1), len(t), axis=0)
                if rot:
                    for bone, axis, deg, period in BREATH:
                        if bone != nm:
                            continue
                        for j, tt in enumerate(t[:, 0]):
                            ang = np.radians(deg) * np.sin(2 * np.pi * tt / period)
                            d = np.array([*(np.array(axis) * np.sin(ang / 2)), np.cos(ang / 2)], dtype=np.float32)
                            v[j] = qmul(v[j], d)
                length = STAND_LEN
            ti = w.add_acc(t, "SCALAR", minmax=True)
            vi = w.add_acc(v, {3: "VEC3", 4: "VEC4"}[v.shape[1]])
            samplers.append({"input": ti, "output": vi, "interpolation": s.get("interpolation", "LINEAR")})
            channels.append({"sampler": len(samplers) - 1, "target": {"node": names[nm], "path": p}})
        anims.append({"name": new_name, "channels": channels, "samplers": samplers})
        print("  %-12s %-40s %5.2fs %d ch" % (new_name, a.get("name"), length, len(channels)))
    js["animations"] = anims
    js["bufferViews"] = w.views
    js["accessors"] = w.accs
    js["buffers"] = [{"byteLength": len(w.buf)}]
    jb = json.dumps(js, separators=(",", ":")).encode()
    while len(jb) % 4:
        jb += b" "
    while len(w.buf) % 4:
        w.buf += b"\0"
    total = 12 + 8 + len(jb) + 8 + len(w.buf)
    with open(out, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<II", len(jb), 0x4E4F534A) + jb)
        f.write(struct.pack("<II", len(w.buf), 0x004E4942) + bytes(w.buf))
    print(out, total // 1024, "KB")


main()
