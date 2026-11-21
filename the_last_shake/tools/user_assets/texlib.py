"""Helpers for fixing the user's PBR texture sets: all maps of one material are edited together."""
import os, numpy as np
from PIL import Image
from scipy import ndimage as ndi

MAPS = ("albedo", "normal_gl", "height", "roughness", "ao", "orm")

def load_set(folder, base, albedo_file=None):
    s = {}
    for m in MAPS:
        f = os.path.join(folder, f"{base}_{m}.png")
        if m == "albedo" and albedo_file:
            f = os.path.join(folder, albedo_file)
        if not os.path.exists(f):
            continue
        im = Image.open(f)
        mode = "L" if m in ("height", "roughness", "ao") else "RGB"
        s[m] = np.asarray(im.convert(mode), np.float32) / 255.0
    return s

def save_set(s, out):
    os.makedirs(out, exist_ok=True)
    for m, a in s.items():
        Image.fromarray(np.clip(a * 255 + 0.5, 0, 255).astype(np.uint8)).save(os.path.join(out, m + ".png"))

def lum(a):
    return a @ np.array([0.2126, 0.7152, 0.0722], np.float32) if a.ndim == 3 else a

def soft(mask, sigma):
    return np.clip(ndi.gaussian_filter(mask.astype(np.float32), sigma), 0, 1)

def blend(dst, src, w):
    w = w[..., None] if dst.ndim == 3 else w
    return dst * (1 - w) + src * w

# ---------------------------------------------------------------- seams
def _cut_path(err):
    """Minimum-error vertical path through err (H x B); returns column per row."""
    H, B = err.shape
    E = err.copy()
    back = np.zeros((H, B), np.int32)
    for y in range(1, H):
        prev = E[y - 1]
        l = np.r_[np.inf, prev[:-1]]; r = np.r_[prev[1:], np.inf]
        st = np.stack([l, prev, r])
        k = st.argmin(0)
        E[y] += st[k, np.arange(B)]
        back[y] = np.arange(B) + k - 1
    path = np.zeros(H, np.int32)
    path[-1] = int(E[-1, 2:-2].argmin()) + 2
    for y in range(H - 1, 0, -1):
        path[y - 1] = back[y, path[y]]
    return path

def tile_x(s, B, x0=0, Wn=None, feather=1.5):
    """Make every map of the set periodic along X. Uses columns [x0, x0+Wn+B): the last B columns are
    stitched over the first B along a minimum-error cut. Output width Wn (then resized back)."""
    W = s["albedo"].shape[1]
    if Wn is None:
        Wn = W - x0 - B
    a = {m: v[:, x0:x0 + Wn + B] for m, v in s.items()}
    A = a["albedo"]; N = a.get("normal_gl", A)
    err = ((A[:, Wn:Wn + B] - A[:, :B]) ** 2).sum(-1) + 0.5 * ((N[:, Wn:Wn + B] - N[:, :B]) ** 2).sum(-1)
    err = ndi.gaussian_filter(err, 1.0)
    path = _cut_path(err)
    H = A.shape[0]
    take_tail = (np.arange(B)[None, :] < path[:, None]).astype(np.float32)   # 1 → use tail (img[Wn+x])
    take_tail = ndi.gaussian_filter1d(take_tail, feather, axis=1) if feather else take_tail
    out = {}
    for m, v in a.items():
        o = v[:, :Wn].copy()
        o[:, :B] = blend(v[:, :B], v[:, Wn:Wn + B], take_tail)
        out[m] = o
    return out, path

def tile_y(s, B, y0=0, Hn=None, feather=1.5):
    t = {m: np.swapaxes(v, 0, 1) for m, v in s.items()}
    o, p = tile_x(t, B, y0, Hn, feather)
    return {m: np.swapaxes(v, 0, 1) for m, v in o.items()}, p

def resize_set(s, size):
    out = {}
    for m, v in s.items():
        im = Image.fromarray(np.clip(v * 255 + 0.5, 0, 255).astype(np.uint8))
        out[m] = np.asarray(im.resize(size, Image.LANCZOS), np.float32) / 255.0
    if "normal_gl" in out:   # renormalise
        n = out["normal_gl"] * 2 - 1
        n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-6
        out["normal_gl"] = n * 0.5 + 0.5
    return out

def seam_score(a, axis):
    """edge-wrap difference relative to the average neighbour difference (≈1 means invisible seam)"""
    a = a if axis == 1 else np.swapaxes(a, 0, 1)
    edge = np.abs(a[:, 0] - a[:, -1]).mean()
    inner = np.abs(a[:, 1:] - a[:, :-1]).mean()
    return edge / inner

def edge_match_x(s, R=120, sigma=3.0):
    """For sets whose structure already lines up across the X edge: remove the colour/brightness step at the
    wrap by spreading half of it over R pixels on each side."""
    out = {}
    for m, v in s.items():
        W = v.shape[1]
        D = v[:, :1] - v[:, -1:]
        D = ndi.gaussian_filter1d(D, sigma, axis=0)
        t = np.clip(1 - np.arange(W, dtype=np.float32) / R, 0, 1)       # 1 at left edge → 0
        u = t[::-1]                                                       # 1 at right edge
        sh = (1, W) + ((1,) if v.ndim == 3 else ())
        o = v - D * 0.5 * t.reshape(sh) + D * 0.5 * u.reshape(sh)
        out[m] = np.clip(o, 0, 1)
    if "normal_gl" in out:
        n = out["normal_gl"] * 2 - 1; n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-6; out["normal_gl"] = n * .5 + .5
    return out
