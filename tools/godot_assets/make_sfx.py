#!/usr/bin/env python3
"""Синтезирует звуки сюжета «The Last Shake» (WAV 22050 Гц, моно) в the_last_shake/story/sfx/.
Голоса — не речь, а «звук голоса» под субтитры: крик, рык, плач, смех, шёпот.
Запуск: python3 make_sfx.py <папка the_last_shake/story/sfx>"""
import math
import os
import sys
import wave

import numpy as np

SR = 22050
OUT = sys.argv[1]
rng = np.random.default_rng(1975)
os.makedirs(OUT, exist_ok=True)


def t_(sec):
    return np.arange(int(sec * SR)) / SR


def save(name, x, gain=0.9):
    x = np.asarray(x, float)
    peak = np.max(np.abs(x)) + 1e-9
    x = x / peak * gain
    # мягкий спад в конце, чтобы не щёлкало
    n = min(len(x), 200)
    x[-n:] *= np.linspace(1, 0, n)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def noise(sec):
    return rng.standard_normal(int(sec * SR))


def onepole_lp(x, fc):
    a = math.exp(-2 * math.pi * fc / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def lp(x, fc, order=2):
    for _ in range(order):
        x = onepole_lp(x, fc)
    return x


def hp(x, fc):
    return x - lp(x, fc, 1)


def biquad_bp(x, f0, q):
    w0 = 2 * math.pi * f0 / SR
    alpha = math.sin(w0) / (2 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, o
        y[i] = o
    return y


def bp(x, lo, hi):
    return hp(lp(x, hi), lo)


def env(n, a, d, sustain=1.0, r=None):
    e = np.ones(n) * sustain
    na = max(1, int(a * SR))
    e[:na] = np.linspace(0, 1, na) if na < n else np.linspace(0, 1, n)[:na]
    if r is None:
        return e * np.exp(-np.arange(n) / SR / max(d, 1e-3)) if d > 0 else e
    nr = max(1, int(r * SR))
    e[-nr:] *= np.linspace(1, 0, nr)
    return e


def decay(sec, tau):
    return np.exp(-t_(sec) / tau)


def reverb(x, room=0.35, tail=1.2):
    n = len(x) + int(tail * SR)
    y = np.zeros(n)
    y[:len(x)] += x
    for k, (dl, g) in enumerate([(0.029, 0.5), (0.037, 0.45), (0.044, 0.42), (0.053, 0.38), (0.067, 0.33), (0.079, 0.3)]):
        d = int(dl * SR)
        fb = g * room * 2
        buf = np.zeros(n)
        buf[:len(x)] = x
        for i in range(d, n):
            buf[i] += buf[i - d] * fb
        y += lp(buf, 3500, 1) * 0.18
    return y


def voice(sec, f0, formants, breath=0.15, jitter=0.02, vib=(5.5, 0.03), rough=0.0):
    """Голос: импульсы связок (пила с дрожанием) через форманты гласной."""
    n = int(sec * SR)
    f0 = np.broadcast_to(np.asarray(f0, float), (n,)) if np.ndim(f0) == 0 else np.asarray(f0, float)
    tt = np.arange(n) / SR
    fm = f0 * (1 + vib[1] * np.sin(2 * math.pi * vib[0] * tt)) * (1 + jitter * lp(rng.standard_normal(n), 30, 1) * 8)
    if rough > 0:
        fm *= 1 + rough * np.sign(np.sin(2 * math.pi * fm * tt / 2)) * 0.03
    ph = np.cumsum(fm / SR)
    src = (ph % 1.0) * 2 - 1
    src = src - lp(src, 80, 1)
    src += breath * rng.standard_normal(n)
    out = np.zeros(n)
    for f, q, g in formants:
        out += biquad_bp(src, f, q) * g
    return out


A = [(800, 6, 1.0), (1200, 8, 0.6), (2600, 10, 0.25)]      # «а»
O = [(500, 6, 1.0), (900, 8, 0.5), (2400, 10, 0.15)]       # «о»
U = [(350, 6, 1.0), (750, 8, 0.4), (2300, 10, 0.1)]        # «у»
E = [(500, 6, 1.0), (1800, 9, 0.5), (2600, 10, 0.2)]       # «э»


def glide(sec, a, b, curve=1.0):
    x = np.linspace(0, 1, int(sec * SR)) ** curve
    return a + (b - a) * x


def syllables(n, rate, duty=0.6, rnd=0.3):
    """Огибающая слогов: включения с частотой rate."""
    e = np.zeros(n)
    i = 0
    while i < n:
        ln = int(SR / rate * duty * (1 + rnd * rng.uniform(-1, 1)))
        gap = int(SR / rate * (1 - duty) * (1 + rnd * rng.uniform(-1, 1)))
        seg = np.sin(np.linspace(0, math.pi, max(ln, 2))) ** 0.7
        e[i:i + len(seg)] = seg[:max(0, min(len(seg), n - i))]
        i += ln + gap
    return e


def mix(*xs):
    n = max(len(x) for x in xs)
    out = np.zeros(n)
    for x in xs:
        out[:len(x)] += x
    return out


def hits(sec, times, make):
    out = np.zeros(int(sec * SR))
    for tm in times:
        h = make()
        i = int(tm * SR)
        m = min(len(h), len(out) - i)
        if m > 0:
            out[i:i + m] += h[:m]
    return out


def thump(f=70, tau=0.12, sec=0.5, click=0.3):
    tt = t_(sec)
    s = np.sin(2 * math.pi * f * tt * (1 + 0.6 * np.exp(-tt / 0.02))) * np.exp(-tt / tau)
    c = lp(noise(sec), 2500) * np.exp(-tt / 0.012) * click
    return s + c


def metal(freqs, sec, tau, amp=None):
    tt = t_(sec)
    out = np.zeros(len(tt))
    for k, f in enumerate(freqs):
        a = 1.0 / (k + 1) if amp is None else amp[k]
        out += a * np.sin(2 * math.pi * f * tt + rng.uniform(0, 6)) * np.exp(-tt / (tau / (1 + 0.3 * k)))
    return out


# ---------------------------------------------------------------------------- голоса
def scream(sec, f_from, f_to, form, rough=0.0):
    f0 = glide(sec, f_from, f_to, 0.6) * (1 + 0.04 * np.sin(2 * math.pi * 7 * t_(sec)))
    v = voice(sec, f0, form, breath=0.35, jitter=0.04, vib=(7, 0.04), rough=rough)
    v = np.tanh(v / (np.std(v) * 1.2 + 1e-9) * 1.6)
    return v * env(len(v), 0.06, 0, r=0.5)


save("scream_pain", reverb(scream(2.4, 420, 560, A) * 0.9 + scream(2.4, 405, 520, E) * 0.4, 0.4, 1.4))
save("mom_scream", reverb(scream(1.6, 460, 640, A, 0.3), 0.3, 0.8))
save("hero_scream", reverb(scream(2.2, 300, 430, A, 0.2), 0.3, 1.2))


def shout(sec, f_lo, f_hi, rate=4.5):
    n = int(sec * SR)
    f0 = f_lo + (f_hi - f_lo) * (0.5 + 0.5 * np.sin(2 * math.pi * 0.7 * t_(sec)))
    seq = [A, O, E, A, U, A]
    out = np.zeros(n)
    seg = n // len(seq)
    for k, form in enumerate(seq):
        part = voice(seg / SR, f0[k * seg:(k + 1) * seg], form, breath=0.3, jitter=0.05, rough=1.0)
        out[k * seg:(k + 1) * seg] = part
    out *= syllables(n, rate, 0.75, 0.35)
    out = np.tanh(out / (np.std(out) + 1e-9) * 2.2)
    return out


save("psycho_shout", reverb(shout(2.8, 125, 190), 0.45, 1.2))
save("psycho_roar", reverb(shout(1.8, 150, 230, 3.0), 0.35, 0.9))


def crying(sec):
    n = int(sec * SR)
    f0 = 330 + 50 * np.sin(2 * math.pi * 0.37 * t_(sec)) + 40 * (rng.random(n) > 0.9995).cumsum() % 3
    v = voice(sec, f0, U, breath=0.6, jitter=0.08, vib=(6, 0.06))
    sob = syllables(n, 1.6, 0.55, 0.5) ** 1.5
    v *= sob
    gasps = bp(noise(sec), 600, 2500) * syllables(n, 0.5, 0.15, 0.6) * 0.5
    return lp(v + gasps, 1400)


save("crying", crying(6.0), 0.7)


def laughter(sec):
    n = int(sec * SR)
    f0 = glide(sec, 190, 140)
    v = voice(sec, f0, A, breath=0.5, jitter=0.03)
    v *= syllables(n, 5.0, 0.45, 0.2) * env(n, 0.05, 0, r=0.6)
    return lp(v, 1200)


save("laughter", reverb(laughter(2.6), 0.5, 1.5), 0.6)


def whisper(parts):
    out = []
    for kind, sec in parts:
        n = int(sec * SR)
        x = noise(sec)
        if kind == "s":
            y = bp(x, 3500, 8000) * 0.6
        elif kind == "sh":
            y = bp(x, 1800, 5000) * 0.6
        elif kind in ("m", "n"):
            y = lp(x, 400) * 0.6
        elif kind == "_":
            y = np.zeros(n)
        else:
            form = {"a": A, "o": O, "e": E, "u": U, "i": E}[kind]
            y = sum(biquad_bp(x, f, q) * g for f, q, g in form) * 1.2
        out.append(y * np.sin(np.linspace(0, math.pi, n)) ** 0.5)
    return np.concatenate(out)


save("whisper_saman", reverb(whisper([("s", 0.22), ("a", 0.3), ("m", 0.12), ("a", 0.28), ("n", 0.16)]), 0.6, 1.8), 0.55)
_radio = whisper([("n", 0.1), ("e", 0.16), ("_", 0.05), ("o", 0.14), ("_", 0.03), ("o", 0.12), ("_", 0.04), ("a", 0.12),
                  ("sh", 0.1), ("i", 0.12), ("_", 0.03), ("a", 0.12), ("_", 0.04), ("s", 0.12), ("a", 0.22)])
_radio = np.tanh(bp(_radio, 350, 3000) * 3)
save("radio_whisper", _radio * (0.85 + 0.15 * np.sign(np.sin(2 * math.pi * 50 * t_(len(_radio) / SR)))), 0.8)


def gasp():
    n = int(1.1 * SR)
    x = noise(1.1)
    y = sum(biquad_bp(x, f, q) * g for f, q, g in A) * np.linspace(0.2, 1, n) ** 2
    v = voice(1.1, glide(1.1, 250, 420), A, breath=0.8) * 0.4 * np.linspace(0, 1, n) ** 3
    return (y + v) * env(n, 0.3, 0, r=0.15)


save("gasp", gasp())


def choke():
    n = int(2.2 * SR)
    v = voice(2.2, 115 + 30 * np.sin(2 * math.pi * 3 * t_(2.2)), O, breath=0.5, jitter=0.1, rough=1.0)
    v *= syllables(n, 7.0, 0.5, 0.6)
    return lp(np.tanh(v * 3), 1500)


save("choke", choke())

# ---------------------------------------------------------------------------- удары, грохот
save("crash_heavy", reverb(mix(thump(48, 0.35, 1.2, 0.6) * 1.2, hits(1.8, sorted(rng.uniform(0.05, 0.9, 9)),
                    lambda: metal(rng.uniform(300, 2600, 4), 0.6, 0.12) * rng.uniform(0.2, 0.6)), lp(noise(1.8), 1500) * decay(1.8, 0.3) * 0.5), 0.5, 1.2))
save("metal_bang", reverb(metal([220, 563, 1130, 1810, 2650], 1.4, 0.5) + thump(90, 0.06, 1.4, 0.8) * 0.6, 0.4, 0.8))
save("door_slam", reverb(thump(75, 0.14, 0.9, 0.9) + lp(noise(0.9), 1800) * decay(0.9, 0.05) * 0.8, 0.5, 1.0))
save("glass_bang", hits(1.6, [0.0, 0.42, 0.86], lambda: thump(120, 0.05, 0.5, 0.5) +
                        metal([2300, 3700, 5100], 0.5, 0.08, [0.35, 0.25, 0.15]) * (1 + 0.5 * np.sin(2 * math.pi * 40 * t_(0.5)))))
save("punch", thump(95, 0.06, 0.35, 1.0) + lp(noise(0.35), 3000) * decay(0.35, 0.02) * 0.6)
_wn = int(0.45 * SR)
_w = noise(0.45)
_sweep = np.zeros(_wn)
for k in range(6):
    seg = slice(k * _wn // 6, (k + 1) * _wn // 6)
    _sweep[seg] = bp(_w, 300 + k * 260, 900 + k * 420)[seg]
save("whoosh", _sweep * np.sin(np.linspace(0, math.pi, _wn)) ** 2, 0.6)
save("body_fall", thump(55, 0.18, 0.9, 0.5) + lp(noise(0.9), 900) * decay(0.9, 0.12) * 0.5)
save("knock", reverb(hits(1.4, [0.0, 0.3, 0.6], lambda: thump(140, 0.05, 0.4, 0.7) + bp(noise(0.4), 350, 900) * decay(0.4, 0.04) * 1.5), 0.4, 0.6))
save("grandpa_bang", reverb(hits(1.3, [0.0, 0.35, 0.62, 0.95], lambda: mix(thump(85, 0.09, 0.5, 1.0) * 1.3,
                           metal([900, 1500], 0.4, 0.06, [0.15, 0.1]))), 0.4, 0.6))
save("door_burst", reverb(mix(thump(55, 0.3, 1.8, 1.0) * 1.3, hits(1.8, sorted(rng.uniform(0.0, 0.6, 30)),
                         lambda: bp(noise(0.08), 900, 5000) * decay(0.08, 0.015) * rng.uniform(0.2, 0.8)), metal([1400, 2100], 1.2, 0.3, [0.2, 0.12])), 0.5, 1.2))
save("instruments_fall", reverb(mix(metal([600, 1700, 2900], 0.6, 0.2) * 0.8, hits(2.2, sorted(np.concatenate([[0.05], rng.uniform(0.1, 1.6, 22) ** 1.3])),
                               lambda: metal(rng.uniform(2000, 6500, 3), 0.35, 0.05) * rng.uniform(0.1, 0.5))), 0.5, 1.4))
save("debris", hits(1.8, sorted(rng.exponential(0.25, 40)), lambda: lp(noise(0.12), rng.uniform(800, 3000)) * decay(0.12, 0.03) * rng.uniform(0.2, 1)) + thump(50, 0.2, 1.8, 0.3) * 0.5)
save("beam_hit", reverb(thump(38, 0.5, 2.4, 1.0) * 1.5 + metal([150, 410, 870, 1320], 2.4, 0.6) * 0.7 +
                       hits(2.4, sorted(rng.uniform(0.05, 1.5, 30)), lambda: lp(noise(0.1), 2500) * decay(0.1, 0.03) * rng.uniform(0.1, 0.6)), 0.5, 1.5))
_cc = lp(noise(2.6), 700) * np.linspace(0.1, 1, int(2.6 * SR)) ** 2
_ct = thump(35, 0.6, 2.6, 0.4)
save("ceiling_collapse", mix(_cc, _ct * (np.arange(len(_ct)) > int(1.9 * SR))))

# ---------------------------------------------------------------------------- шаги, дыхание, скрипы
save("run_steps", hits(2.0, np.arange(0, 2.0, 0.3), lambda: thump(70, 0.05, 0.25, 0.6) + bp(noise(0.25), 800, 3000) * decay(0.25, 0.03) * 0.5))
save("barefoot_steps", hits(2.0, np.arange(0, 2.0, 0.27) + rng.uniform(0, 0.02, 8)[:len(np.arange(0, 2.0, 0.27))],
                            lambda: bp(noise(0.12), 900, 4000) * decay(0.12, 0.018) + thump(110, 0.02, 0.12, 0.2) * 0.4), 0.7)
_b = t_(3.0)
_breath = bp(noise(3.0), 450, 1800) * (np.maximum(0, np.sin(2 * math.pi * _b / 1.5)) ** 1.5 + 0.55 * np.maximum(0, -np.sin(2 * math.pi * _b / 1.5)) ** 2)
save("breathing", _breath, 0.6)
_c = t_(2.2)
save("metal_creak", reverb(np.sin(2 * math.pi * np.cumsum(650 + 220 * np.sin(2 * math.pi * 1.3 * _c) + 40 * lp(noise(2.2), 20) * 20) / SR)
                          * (0.6 + 0.4 * np.sign(np.sin(2 * math.pi * 33 * _c))) * env(len(_c), 0.2, 0, r=0.6) * 0.5, 0.5, 1.0), 0.6)
save("gurney_roll", hits(2.6, np.cumsum(rng.uniform(0.02, 0.05, 80)), lambda: bp(noise(0.03), 1500, 4500) * decay(0.03, 0.006) * rng.uniform(0.2, 0.9))
     + np.sin(2 * math.pi * np.cumsum(1700 + 300 * np.sin(2 * math.pi * 3 * t_(2.6))) / SR) * 0.08 * (rng.random(int(2.6 * SR)) > 0.3)
     + lp(noise(2.6), 150) * 0.6)
save("footstep_slow", thump(80, 0.05, 0.4, 0.4) + bp(noise(0.4), 400, 2000) * decay(0.4, 0.05) * 0.4, 0.6)

# ---------------------------------------------------------------------------- фон, радио, приборы
_rt = t_(4.0)
_rh = bp(noise(4.0), 300, 3500) * 0.5 + 0.25 * np.sin(2 * math.pi * 50 * _rt) + hits(4.0, sorted(rng.uniform(0, 3.9, 25)), lambda: noise(0.01) * 0.8)
save("radio_hiss", _rh, 0.6)
_q = t_(6.0)
_rumble = lp(noise(6.0), 60, 3) * (0.7 + 0.3 * np.sin(2 * math.pi * 0.4 * _q)) + lp(noise(6.0), 200) * 0.15
save("quake_rumble", _rumble + hits(6.0, sorted(rng.uniform(0, 5.5, 6)), lambda: metal(rng.uniform(80, 300, 2), 0.8, 0.3) * 0.15))
save("monitor_beep", np.sin(2 * math.pi * 1000 * t_(0.16)) * env(int(0.16 * SR), 0.005, 0, r=0.02), 0.5)
_h = t_(4.0)
save("hospital_hum", 0.5 * np.sin(2 * math.pi * 100 * _h) + 0.2 * np.sin(2 * math.pi * 200 * _h) + lp(noise(4.0), 500) * 0.3, 0.35)
save("heartbeat", hits(1.0, [0.0, 0.22], lambda: thump(45, 0.07, 0.3, 0.1)), 0.8)
_s = t_(3.0)
_st = sum(np.sign(np.sin(2 * math.pi * f * _s)) * 0.2 for f in [92.5, 98, 138.6, 146.8, 207.6]) * env(len(_s), 0.02, 1.2)
save("stinger", lp(_st, 2500) + bp(noise(3.0), 500, 6000) * env(len(_s), 0.01, 0.4) * 0.6)
_d = t_(8.0)
save("drone_low", (np.sin(2 * math.pi * 55 * _d) + np.sin(2 * math.pi * 55.7 * _d) + 0.5 * np.sin(2 * math.pi * 82.4 * _d + np.sin(2 * math.pi * 0.1 * _d))) * 0.3
     + lp(noise(8.0), 300) * 0.3, 0.5)
save("door_creak_slow", reverb(np.sin(2 * math.pi * np.cumsum(240 + 120 * np.sin(2 * math.pi * 0.6 * t_(2.5)) + 30 * lp(noise(2.5), 15) * 30) / SR)
                              * (0.5 + 0.5 * np.sign(np.sin(2 * math.pi * 21 * t_(2.5)))) * env(int(2.5 * SR), 0.3, 0, r=0.5), 0.5, 1.0), 0.6)
print("written to", OUT, len([f for f in os.listdir(OUT) if f.endswith(".wav")]), "files")
