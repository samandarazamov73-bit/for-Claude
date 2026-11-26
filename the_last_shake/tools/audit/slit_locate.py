# Где в здании щель: луч из камеры через центр каждой синей полоски — до первого выхода из комнат этажа.
import sys, os, json, math, numpy as np
from PIL import Image
from scipy import ndimage
src = sys.argv[1]
only = set(sys.argv[2:])
L = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "sanatorium", "assets", "level.json")))
rows = [l.rstrip("\n").split("\t") for l in open(f"{src}/manifest.txt") if l.strip()]
byroom = {}
for i, r in enumerate(rows):
    byroom.setdefault(r[1], []).append(i)
def inside(x, z, y, lvl):
    for r in L["rooms"]:
        k = r["kind"]
        if r["level"] != lvl and not k.startswith("stair") and k != "shaft":
            continue
        if not (r["floor_y"] - 0.5 <= y <= r["ceil_y"] + 0.5):
            continue
        for q in r["rects"]:
            if q[0] <= x <= q[1] and q[2] <= z <= q[3]:
                return r["id"]
    return None
for i, (nm, rid, name, kind, pos) in enumerate(rows):
    if only and nm.split("_")[0] not in only:
        continue
    x = np.asarray(Image.open(f"{src}/{nm}_x.jpg").convert("RGB")).astype(int)
    blue = (x[..., 2] > 90) & (x[..., 2] > 1.6 * x[..., 0] + 20)
    thin = blue & ~ndimage.binary_opening(blue, structure=np.ones((7, 7)))
    lab, nl = ndimage.label(thin, structure=np.ones((3, 3)))
    if nl == 0:
        continue
    lvl = int(rid[1])
    p0 = np.array([float(v) for v in pos.split(",")])
    grp = byroom[rid]; k = grp.index(i); partner = grp[k ^ 1] if (k ^ 1) < len(grp) else grp[k]
    p1 = np.array([float(v) for v in rows[partner][4].split(",")])
    room = next(r for r in L["rooms"] if r["id"] == rid)
    tgt = np.array([p1[0], room["floor_y"] + 0.55, p1[2]])
    f = tgt - p0; f /= np.linalg.norm(f)
    rgt = np.cross(f, [0, 1, 0]); rgt /= np.linalg.norm(rgt); up = np.cross(rgt, f)
    H, W = x.shape[:2]; th = math.tan(math.radians(82) / 2)
    for c in range(1, nl + 1):
        ys, xs = np.nonzero(lab == c)
        if len(ys) < 30:
            continue
        u = (xs.mean() / W * 2 - 1) * th * W / H; v = (1 - ys.mean() / H * 2) * th
        d = f + rgt * u + up * v; d /= np.linalg.norm(d)
        last = None
        for t in np.arange(0.1, 40, 0.04):
            q = p0 + d * t
            r = inside(q[0], q[2], q[1], lvl)
            if r is None:
                print(f"{nm}: slit {len(ys)} px at px({xs.mean():.0f},{ys.mean():.0f}) -> wall near ({q[0]:.2f}, {q[1]:.2f}, {q[2]:.2f}) leaving {last}")
                break
            last = r
