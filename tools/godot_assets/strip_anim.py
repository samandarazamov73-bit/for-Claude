"""Убирает из анимаций каналы головы и шеи (их поворачивает игра) и лишние каналы масштаба/сдвига."""
import json, struct, sys
src, dst = sys.argv[1], sys.argv[2]
b = open(src, "rb").read()
ln, = struct.unpack_from("<I", b, 12)
js = json.loads(b[20:20 + ln])
rest = b[20 + ln:]
names = [n.get("name", "") for n in js["nodes"]]
for a in js["animations"]:
    keep = []
    for c in a["channels"]:
        nm, path = names[c["target"]["node"]], c["target"]["path"]
        if nm in ("Neck", "Head"):
            continue
        if path == "scale" or (path == "translation" and nm != "Hips"):
            continue
        keep.append(c)
    used = sorted(set(c["sampler"] for c in keep))
    remap = {old: i for i, old in enumerate(used)}
    a["samplers"] = [a["samplers"][i] for i in used]
    for c in keep:
        c["sampler"] = remap[c["sampler"]]
    a["channels"] = keep
    print(a["name"], "channels", len(keep))
jb = json.dumps(js, separators=(",", ":")).encode()
while len(jb) % 4:
    jb += b" "
total = 12 + 8 + len(jb) + len(rest)
open(dst, "wb").write(struct.pack("<4sII", b"glTF", 2, total) + struct.pack("<II", len(jb), 0x4E4F534A) + jb + rest)
