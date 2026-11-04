"""Данные для превью леса: та же дорога (route.gd), те же правила посадки деревьев (forest.gd), то же время суток (daylight.gd)."""
import json, math, random, sys
SP = sys.argv[1]
src = open(SP + "/route_port.py").read().split("for minutes in")[0]
src = src.replace("BUS_CRUISE=11.5", "BUS_CRUISE=12.5")
a = src.index("        defs=["); b = src.index("        s.pieces=[]")
src = src[:a] + '''        defs=[("S",400.0),("S",160.0*scale),("A",140.0,28.0),("S",230.0*scale),("A",110.0,-40.0),("S",260.0*scale),("A",200.0,22.0),
              ("S",170.0*scale),("A",160.0,-26.0),("S",300.0*scale),("A",130.0,34.0),("S",240.0*scale+160.0),("A",120.0,-38.0),("S",700.0)]
''' + src[b:]
a = src.index("        sl=s.pieces[5]"); b = src.index("        s.start_s=392.0")
src = src[:a] + '''        s.events=[{"id":"camp","kind":"stop","s":s.pieces[3]["s0"]+s.pieces[3]["len"]*0.55},{"id":"spring","kind":"stop","s":s.pieces[9]["s0"]+s.pieces[9]["len"]*0.5},{"id":"sanatorium","kind":"final","s":s.pieces[12]["s0"]-70.0}]
''' + src[b:]
g = {}
exec(src, g)
r = g["Route"](); r.fit(240.0)

def sample(s):
    cs = min(max(s, 0.0), r.length); p = r.piece_at(cs); x, z, th = r._eval(p, cs - p["s0"]); extra = s - cs
    dx, dz = math.cos(th), math.sin(th)
    return {"x": x + dx * extra, "z": z + dz * extra, "dx": dx, "dz": dz, "rx": -dz, "rz": dx}
def point(s, lat):
    q = sample(s); return [q["x"] + q["rx"] * lat, q["z"] + q["rz"] * lat]
def yaw(s):
    q = sample(s); return math.atan2(-q["dx"], -q["dz"])

camp = r.events[0]["s"]; final = r.events[2]["s"]
bus_s = r.pieces[6]["s0"] + r.pieces[6]["len"] * 0.45                 # плавный поворот направо после остановки
progress = (bus_s - r.start_s) / (final - r.start_s)
t = progress * 0.38
KEYS = [[0.0, 26.0, (1.0, 0.94, 0.84), 1.25, (0.38, 0.53, 0.72), (0.84, 0.82, 0.74), (0.7, 0.71, 0.68), 0.005, 1.25],
        [0.38, 10.0, (1.0, 0.76, 0.52), 1.1, (0.32, 0.4, 0.6), (0.96, 0.7, 0.45), (0.64, 0.54, 0.45), 0.007, 1.0]]
k = t / 0.38
lerp = lambda a, b: a + (b - a) * k
lc = lambda a, b: [lerp(a[i], b[i]) for i in range(3)]
A, B = KEYS
day = {"t": t, "elev": lerp(A[1], B[1]), "sun_color": lc(A[2], B[2]), "sun_energy": lerp(A[3], B[3]), "top": lc(A[4], B[4]),
       "horizon": lc(A[5], B[5]), "fog": lc(A[6], B[6]), "fog_density": lerp(A[7], B[7]), "ambient": lerp(A[8], B[8])}
road = []
s = bus_s - 220
while s < bus_s + 420:
    q = sample(s); road.append([s, q["x"], q["z"], q["rx"], q["rz"]]); s += 2.0
rng = random.Random(1975)
trees = []
GAP, F0, F1 = 4.5, 12.0, 52.0
s = bus_s - 220
while s < bus_s + 420:
    for side in (-1.0, 1.0):
        lat = F0
        while lat < F1:
            ss = s + rng.uniform(-0.45, 0.45) * GAP; ll = lat + rng.uniform(-0.4, 0.4) * GAP
            rr = rng.random(); kind = "spruce" if rr < 0.42 else ("pine" if rr < 0.8 else "birch")
            px, pz = point(ss, side * ll)
            sc = rng.uniform(0.75, 1.3) * (0.65 + 0.35 * min(1.0, max(0.0, (ll - F0) / 8.0)))
            trees.append([kind, px, pz, rng.random() * math.tau, sc, sc * rng.uniform(0.9, 1.2), rng.randrange(4)])
            lat += GAP * rng.uniform(0.8, 1.25)
    s += GAP
sb = bus_s - 220
while sb < bus_s + 420:
    for side in (-1.0, 1.0):
        if rng.random() < 0.55:
            px, pz = point(sb + rng.uniform(-2, 2), side * rng.uniform(7.2, 13.0))
            sc = rng.uniform(0.75, 1.3)
            trees.append(["bush", px, pz, rng.random() * math.tau, sc, sc * rng.uniform(0.9, 1.2), rng.randrange(4)])
    sb += 6.0
bx, bz = point(bus_s, 1.8)
out = {"day": day, "road": road, "trees": trees, "bus": {"x": bx, "z": bz, "yaw": yaw(bus_s)},
       "ahead": point(bus_s + 30, -1.2), "behind": point(bus_s - 34, 2.6), "ahead_look": point(bus_s - 2, 1.8), "high": point(bus_s + 70, 14.0)}
json.dump(out, open(SP + "/tools/www/forest_data.json", "w"))
print(f"bus at s={bus_s:.0f}, progress {progress:.2f}, time t={t:.2f}, sun elev {day['elev']:.1f}°, trees {len(trees)}")
