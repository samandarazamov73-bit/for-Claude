import json, os, re, subprocess, sys
lst, out = sys.argv[1], sys.argv[2]
items = json.load(open(lst))
fail = []
for e in items:
    fid = re.search(r"id=([\w-]+)|/d/([\w-]+)", e["url"])
    fid = fid.group(1) or fid.group(2)
    path = os.path.abspath(os.path.join(out, e["path"]))
    if not path.startswith(os.path.abspath(out)):
        fail.append(e["path"]); continue
    if os.path.exists(path) and os.path.getsize(path) > 0:
        continue
    os.makedirs(os.path.dirname(path), exist_ok=True)
    url = f"https://drive.usercontent.google.com/download?id={fid}&export=download&confirm=t"
    for attempt in range(4):
        r = subprocess.run(["curl", "-sS", "-L", "--fail", "--max-time", "300", "-o", path + ".part", url])
        if r.returncode == 0:
            os.replace(path + ".part", path); break
    else:
        fail.append(e["path"])
print("done", len(items) - len(fail), "of", len(items)); print("\n".join(fail))
