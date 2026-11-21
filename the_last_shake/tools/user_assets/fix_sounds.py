"""Clean the user's sounds: game names, 44.1 kHz 16-bit, trimmed silence, peak -1 dBFS, seamless loops."""
import sys, os, re, wave, json, numpy as np
from scipy.signal import resample_poly

SRC, OUT = sys.argv[1], sys.argv[2]
RENAME = {"crying girl": "crying", "enginea": "engine", "for iron doors": "door_open_metal", "heartbeat full.wav": "heartbeat_full",
          "punch for budy Saman": "punch", "run_steps step sound": "run_steps", "slap for face Saman": "slap"}
LOOPS = {"ambience_loop", "drone_low", "drone_low_2", "fluo_buzz_loop", "hospital_hum", "lift_motor_loop", "radio_hiss",
         "wind", "engine", "hospital_alive", "quake_rumble"}
SR = 44100

def read(p):
    w = wave.open(p); n, ch, sr, sw = w.getnframes(), w.getnchannels(), w.getframerate(), w.getsampwidth()
    a = np.frombuffer(w.readframes(n), {2: np.int16, 4: np.int32}[sw]).reshape(-1, ch).astype(np.float32)
    return a / (2 ** (8 * sw - 1)), sr

def write(p, a):
    a = np.clip(a, -1, 1)
    w = wave.open(p, "wb"); w.setnchannels(a.shape[1]); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((a * 32767).astype(np.int16).tobytes()); w.close()

os.makedirs(OUT, exist_ok=True)
rep = {}
for f in sorted(os.listdir(SRC)):
    if not f.lower().endswith(".wav"): continue
    base = re.sub(r"\.wav$", "", f, flags=re.I)
    base = RENAME.get(base, base)
    m = re.match(r"(.*?) (\d+)$", base)
    name = f"{m.group(1)}_{m.group(2)}" if m else base
    name = RENAME.get(name, name)
    a, sr = read(os.path.join(SRC, f))
    if sr != SR:
        g = np.gcd(SR, sr); a = resample_poly(a, SR // g, sr // g, axis=0).astype(np.float32)
    mono = a.mean(1); pk = np.abs(a).max() + 1e-9
    clipped = int((np.abs(a) > 0.999).sum())
    loop = name in LOOPS or name.split("_")[0] in ("drone",) and name.startswith("drone_low")
    note = []
    if loop:
        L = len(a); N = int(min(0.5 * SR, 0.15 * L))
        # tail start T chosen so the tail is in phase with the head (no dip in hums/buzz at the joint)
        win = min(N, int(0.08 * SR)); ref = a[:win].mean(1)
        best = (-2, L - N)
        for T in range(max(N + win, L - N - int(0.3 * SR)), L - N + 1, 7):
            seg = a[T:T + win].mean(1)
            c = float(np.dot(seg, ref) / (np.linalg.norm(seg) * np.linalg.norm(ref) + 1e-9))
            if c > best[0]: best = (c, T)
        T = best[1]
        t = np.linspace(0, np.pi / 2, N, dtype=np.float32)[:, None]
        head = a[:N] * np.sin(t) + a[T:T + N] * np.cos(t)
        a = np.concatenate([head, a[N:T]])
        note.append(f"loop xfade {N / SR:.2f}s, joint corr {best[0]:.2f}")
    else:
        thr = max(pk * 10 ** (-50 / 20), 1e-4)
        idx = np.flatnonzero(np.abs(mono) > thr)
        s0 = max(idx[0] - int(0.010 * SR), 0); s1 = min(idx[-1] + int(0.08 * SR), len(a))
        if s0 > 0.03 * SR or len(a) - s1 > 0.1 * SR:
            note.append(f"trim {s0 / SR:.2f}s/{(len(a) - s1) / SR:.2f}s")
        a = a[s0:s1].copy()
        fi, fo = int(0.003 * SR), int(0.015 * SR)
        if s0 > 0: a[:fi] *= np.linspace(0, 1, fi)[:, None]
        a[-fo:] *= np.linspace(1, 0, fo)[:, None]
    g = 10 ** (-1 / 20) / (np.abs(a).max() + 1e-9)
    if abs(20 * np.log10(g)) > 1.5: note.append(f"gain {20 * np.log10(g):+.1f} dB")
    if clipped: note.append(f"{clipped} clipped samples tamed")
    a = a * g
    write(os.path.join(OUT, name + ".wav"), a)
    rep[name] = dict(src=f, sec=round(len(a) / SR, 2), ch=a.shape[1], loop=bool(loop), notes=note)
    print(f"{name:20s} {len(a) / SR:5.2f}s {'loop' if loop else '    '} {'; '.join(note)}")
json.dump(rep, open(os.path.join(OUT, "_report.json"), "w"), ensure_ascii=False, indent=1)
