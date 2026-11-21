"""Cleaned sounds (fix_sounds output) → the game's sound folders, replacing the synthesized ones with the same name.
Loudness follows the old file (so volumes set in code still fit), peak not above −1 dBFS. Sounds heard from a point
become mono; beds and "in the head" sounds stay stereo. Variants (name_2, name_3 …) go next to the base sound.
Usage: python3 install_sounds.py <clean wav dir> <project root>"""
import sys, os, re, wave, numpy as np

SRC, ROOT = sys.argv[1], sys.argv[2]
DIRS = ["story/sfx", "sanatorium/assets/sfx"]
INTRO = {"engine": "engine", "hiss": "hiss", "wind": "wind"}          # bus engine, door pneumatics, forest wind
NEW_IN_STORY = {"hospital_alive", "heartbeat_full", "slap"}
STEREO = {"ambience_loop", "drone_low", "drone_low_2", "hospital_alive", "wind", "engine", "stinger", "stinger_2",
          "heartbeat", "heartbeat_2", "heartbeat_full", "quake_rumble", "hospital_hum", "hiss"}

def read(p):
    w = wave.open(p); n, ch, sr, sw = w.getnframes(), w.getnchannels(), w.getframerate(), w.getsampwidth()
    a = np.frombuffer(w.readframes(n), {1: np.uint8, 2: np.int16, 4: np.int32}[sw]).reshape(-1, ch).astype(np.float32)
    a = (a - 128) / 128 if sw == 1 else a / (2 ** (8 * sw - 1))
    return a, sr

def write(p, a, sr):
    w = wave.open(p, "wb"); w.setnchannels(a.shape[1]); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes((np.clip(a, -1, 1) * 32767).astype(np.int16).tobytes()); w.close()

def loud(a, sr):
    """RMS of the louder half of 50 ms windows — how loud the sound is where it actually sounds"""
    m = a.mean(1); win = max(int(0.05 * sr), 1)
    k = len(m) // win
    if k < 2:
        return float(np.sqrt((m ** 2).mean()) + 1e-9)
    r = np.sqrt((m[:k * win].reshape(k, win) ** 2).mean(1))
    r = np.sort(r)[k // 2:]
    return float(r.mean() + 1e-9)

for f in sorted(os.listdir(SRC)):
    if not f.endswith(".wav"):
        continue
    name = f[:-4]
    base = re.sub(r"_\d$", "", name)
    a, sr = read(os.path.join(SRC, f))
    if name in INTRO:
        dst_dir = "intro/assets/audio"
    elif name in NEW_IN_STORY:
        dst_dir = "story/sfx"
    else:
        dst_dir = next((d for d in DIRS if os.path.exists(os.path.join(ROOT, d, name + ".wav"))), None)
        if dst_dir is not None:
            base = name                                  # creak_far_1 — own sound, not a variant of creak_far
        else:
            dst_dir = next((d for d in DIRS if os.path.exists(os.path.join(ROOT, d, base + ".wav"))), None)
        if dst_dir is None:
            print("skip (game has no such sound):", name); continue
    os.makedirs(os.path.join(ROOT, dst_dir), exist_ok=True)
    old = os.path.join(ROOT, dst_dir, base + ".wav")
    note = ""
    if os.path.exists(old) and name not in INTRO:
        o, osr = read(old)
        g = loud(o, osr) / loud(a, sr)
        a = a * g
        note = "%+.1f dB to match the old one" % (20 * np.log10(g))
    if a.shape[1] == 2 and name not in STEREO:
        a = a.mean(1, keepdims=True)
    pk = np.abs(a).max()
    if pk > 0.891:
        a = a * (0.891 / pk)
        note += ", peak limited"
    write(os.path.join(ROOT, dst_dir, name + ".wav"), a, sr)
    print(f"{name:20s} → {dst_dir:22s} {'stereo' if a.shape[1] == 2 else 'mono  '} {note}")
