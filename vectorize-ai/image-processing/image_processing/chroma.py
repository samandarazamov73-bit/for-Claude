"""Restoration of subsampled JPEG chroma.

Most JPEG files store colour (Cb, Cr) at half the resolution of brightness
(Y): 4:2:0 averages chroma over 2x2 pixels. Brightness keeps the full
resolution. On thin coloured strokes – small red text on white – the chroma
of every stroke pixel is averaged with the white around it, so the stroke
decodes as a darker, desaturated colour (#a6343f instead of #ef1820) and
its anti-aliased pixels get the wrong hue. Vectorised, such text breaks
into pieces of three or four different colours.

Where an image is locally a mixture of two colours, chroma is a linear
function of luma: ``C = a·Y + b``. The decoder's chroma equals that relation
applied to luma that went through the same subsampling, so ``(a, b)`` can be
estimated in each small window by regressing the observed chroma on a
correspondingly blurred luma, and then applied to the sharp luma. This is
exact for two-colour neighbourhoods. Where chroma does not follow luma
(photographic texture, flat areas) the observed chroma is kept.
"""
from __future__ import annotations

import math

import cv2
import numpy as np

_KR, _KG, _KB = 0.299, 0.587, 0.114


def _to_ycc(rgb: np.ndarray):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    y = _KR * r + _KG * g + _KB * b
    cb = (b - y) / 1.772
    cr = (r - y) / 1.402
    return y, cb, cr


def _to_rgb(y: np.ndarray, cb: np.ndarray, cr: np.ndarray) -> np.ndarray:
    r = y + 1.402 * cr
    b = y + 1.772 * cb
    g = (y - _KR * r - _KB * b) / _KG
    return np.stack([r, g, b], -1)


def restore_subsampled_chroma(rgba: np.ndarray, factors: tuple[int, int], radius: int = 2, eps: float = 30.0) -> np.ndarray:
    """``factors`` = (horizontal, vertical) chroma subsampling, e.g. (2, 2)
    for 4:2:0 or (2, 1) for 4:2:2. Returns a new RGBA array."""
    fx, fy = int(factors[0]), int(factors[1])
    h, w = rgba.shape[:2]
    if (fx <= 1 and fy <= 1) or h < 4 or w < 4:
        return rgba
    rgb = rgba[..., :3].astype(np.float32)
    y, cb, cr = _to_ycc(rgb)
    # luma through the same path as the chroma: averaged per block, then
    # interpolated back (as libjpeg's upsampling does)
    sw, sh = max(1, math.ceil(w / fx)), max(1, math.ceil(h / fy))
    yb = cv2.resize(cv2.resize(y, (sw, sh), interpolation=cv2.INTER_AREA), (w, h), interpolation=cv2.INTER_LINEAR)
    k = (2 * radius + 1, 2 * radius + 1)

    def box(x):
        return cv2.boxFilter(x, -1, k, borderType=cv2.BORDER_REFLECT)

    m_y = box(yb)
    var_y = np.maximum(box(yb * yb) - m_y * m_y, 0.0)
    se = cv2.getStructuringElement(cv2.MORPH_RECT, k)
    out = []
    for c in (cb, cr):
        m_c = box(c)
        var_c = np.maximum(box(c * c) - m_c * m_c, 0.0)
        cov = box(yb * c) - m_y * m_c
        a = cov / (var_y + eps)
        b = m_c - a * m_y
        est = box(a) * y + box(b)
        # never leave the range of chroma actually present nearby: luma
        # ringing would otherwise extrapolate to hues that are not there
        est = np.clip(est, cv2.erode(c, se), cv2.dilate(c, se))
        # Only where chroma really follows luma (edges between two colours)
        # is the estimate used; in photographic texture chroma varies on
        # its own and the observed values are kept.
        r2 = cov * cov / ((var_y + eps) * (var_c + 1.0))
        wgt = box(np.clip((r2 - 0.5) / 0.4, 0.0, 1.0))
        out.append(wgt * est + (1.0 - wgt) * c)
    rgb_new = _to_rgb(y, out[0], out[1])
    res = rgba.copy()
    res[..., :3] = np.clip(rgb_new + 0.5, 0, 255).astype(np.uint8)
    return res
