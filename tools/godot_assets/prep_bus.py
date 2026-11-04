"""Готовит экспорт ЛиАЗ-677 для Godot: поворот под оси игры, прозрачные стёкла, без ламп, JPG-текстуры, метки мест."""
import io, json, math, struct, sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
b = open(src, "rb").read(); off = 12; js = None; binc = None
while off < len(b):
    ln, typ = struct.unpack_from("<II", b, off); off += 8
    if typ == 0x4E4F534A: js = json.loads(b[off:off + ln])
    else: binc = bytes(b[off:off + ln])
    off += ln

def quat_y(deg):
    a = math.radians(deg) / 2
    return [0.0, math.sin(a), 0.0, math.cos(a)]

# --- 1. Стекло: KHR_materials_transmission Godot не понимает (окна стали бы глухими) -> обычная прозрачность
for m in js["materials"]:
    ext = m.get("extensions", {})
    if "KHR_materials_transmission" in ext:
        for k in ("KHR_materials_transmission", "KHR_materials_volume", "KHR_materials_ior"):
            ext.pop(k, None)
        pbr = m.setdefault("pbrMetallicRoughness", {})
        col = pbr.get("baseColorFactor", [1, 1, 1, 1])
        if "Glass_Stalinit" in m["name"]:
            pbr["baseColorFactor"] = [col[0] * 0.55, col[1] * 0.62, col[2] * 0.6, 0.2]
            pbr["roughnessFactor"] = 0.12
        else:
            pbr["baseColorFactor"] = [col[0], col[1], col[2], 0.65]
        m["alphaMode"] = "BLEND"
        if not ext:
            m.pop("extensions", None)

# --- 2. Лампы из файла убираем: свет в салоне ставит игра
for n in js["nodes"]:
    if "extensions" in n:
        n["extensions"].pop("KHR_lights_punctual", None)
        if not n["extensions"]:
            n.pop("extensions")
js.get("extensions", {}).pop("KHR_lights_punctual", None)
if "extensions" in js and not js["extensions"]:
    js.pop("extensions")
js["extensionsUsed"] = [e for e in js.get("extensionsUsed", []) if e not in ("KHR_lights_punctual", "KHR_materials_transmission", "KHR_materials_volume", "KHR_materials_ior")]

# --- 3. Метки мест (в координатах автобуса: X вперёд, Y вверх, Z вправо, к дверям)
FLOOR, CUSHION, HOUSING = 0.80, 0.486, 0.34
root_idx = js["scenes"][0]["nodes"][0]
root = js["nodes"][root_idx]
def add(name, x, y, z, yaw_deg):
    js["nodes"].append({"name": name, "translation": [x, y, z], "rotation": quat_y(yaw_deg)})
    root.setdefault("children", []).append(len(js["nodes"]) - 1)
FACE_FWD = -90.0                      # «вперёд» метки (−Z) смотрит в нос автобуса (+X)
add("anchor_wheelchair", -4.23, FLOOR, -0.796, FACE_FWD)
# Мама стоит у коляски, правой рукой держится за верхний поручень (Z = −0.40, высота 2.60).
# Корпус — между сыном и окном: голова поворачивается то к окну, то к сыну. Кисть в позе hold: (0.26, 1.78, −0.04) от ног.
GRIP = (0.26, 1.78, -0.04)
hx, hz = -4.23, -0.796 + 0.20         # голова героя
mx = -3.36
best = None
for i in range(-70, 30):
    mz = i / 100
    hxv, hzv = hx - mx, hz - mz; L = math.hypot(hxv, hzv); hxv, hzv = hxv / L, hzv / L
    wx, wz = 0.3, -1.0; Lw = math.hypot(wx, wz); wx, wz = wx / Lw, wz / Lw      # окно слева, чуть вперёд
    fx, fz = hxv + wx, hzv + wz; Lf = math.hypot(fx, fz); fx, fz = fx / Lf, fz / Lf
    rx, rz = -fz, fx
    gz = mz + rz * GRIP[0] + fz * (-GRIP[2])
    if best is None or abs(gz + 0.40) < best[0]:
        best = (abs(gz + 0.40), mz, math.degrees(math.atan2(-fx, -fz)), mx + rx * GRIP[0] + fx * (-GRIP[2]))
err, mz, myaw, gx = best
add("anchor_mom", mx, FLOOR, mz, myaw)
print(f"mom at x={mx} z={mz:.2f} yaw={myaw:.1f}, grip at x={gx:.2f} z=-0.40 (err {err:.3f})")
add("anchor_driver", 4.20, 1.185, -0.72, FACE_FWD)
LEFT = [(3.25, True), (2.50, True), (1.75, False), (1.00, False), (0.25, False), (-0.50, False), (-1.25, False), (-2.00, True), (-2.75, True)]
RIGHT = [(2.75, True), (2.00, False), (1.25, False), (0.50, False), (-0.25, False), (-1.00, False), (-1.85, True)]
zL, zR = -(1.25 - 0.061) + 0.05 + 0.43, (1.25 - 0.061) - 0.05 - 0.215
k = 0
for x, raised in LEFT:
    y = FLOOR + (HOUSING if raised else 0) + CUSHION
    add(f"seat_{k:02d}_w{'_r' if raised else ''}", x, y, zL - 0.215, FACE_FWD); k += 1
    if not raised:                     # у приподнятых сидений ноги с прохода свисали бы с подиума
        add(f"seat_{k:02d}_a", x, y, zL + 0.215, FACE_FWD); k += 1
for x, raised in RIGHT:
    y = FLOOR + (HOUSING if raised else 0) + CUSHION
    add(f"seat_{k:02d}_s{'_r' if raised else ''}", x, y, zR, FACE_FWD); k += 1
print("seats", k)

# --- 4. Обёртка: нос автобуса в −Z, двери в +X (как ждёт игра)
js["nodes"].append({"name": "LiAZ677", "rotation": quat_y(90.0), "children": [root_idx]})
js["scenes"][0]["nodes"] = [len(js["nodes"]) - 1]

# --- 5. Текстуры: PNG без прозрачности -> JPG (файл в 2–3 раза меньше)
normal_srcs = set()
for m in js["materials"]:
    if "normalTexture" in m:
        normal_srcs.add(js["textures"][m["normalTexture"]["index"]]["source"])
views = []
for i, bv in enumerate(js["bufferViews"]):
    o = bv.get("byteOffset", 0)
    views.append(binc[o:o + bv["byteLength"]])
before = sum(len(views[im["bufferView"]]) for im in js["images"])
for idx, im in enumerate(js["images"]):
    data = views[im["bufferView"]]
    img = Image.open(io.BytesIO(data)); img.load()
    if img.mode in ("RGBA", "LA") and img.getchannel("A").getextrema()[0] < 250:
        continue
    out = io.BytesIO()
    img.convert("RGB").save(out, "JPEG", quality=92 if idx in normal_srcs else 86, optimize=True)
    if out.tell() < len(data):
        views[im["bufferView"]] = out.getvalue(); im["mimeType"] = "image/jpeg"
after = sum(len(views[im["bufferView"]]) for im in js["images"])
print(f"images {before/1e6:.1f} MB -> {after/1e6:.1f} MB")
newbin = bytearray()
for i, bv in enumerate(js["bufferViews"]):
    while len(newbin) % 4: newbin.append(0)
    bv["byteOffset"] = len(newbin); bv["byteLength"] = len(views[i]); newbin += views[i]
while len(newbin) % 4: newbin.append(0)
js["buffers"] = [{"byteLength": len(newbin)}]
jb = json.dumps(js, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
while len(jb) % 4: jb += b" "
total = 12 + 8 + len(jb) + 8 + len(newbin)
with open(dst, "wb") as f:
    f.write(struct.pack("<4sII", b"glTF", 2, total))
    f.write(struct.pack("<II", len(jb), 0x4E4F534A)); f.write(jb)
    f.write(struct.pack("<II", len(newbin), 0x004E4942)); f.write(newbin)
print("written", dst, total / 1e6, "MB")
