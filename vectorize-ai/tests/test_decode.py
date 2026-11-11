import io

import numpy as np
import pytest
from PIL import Image

from image_processing import ImageDecodeError, decode_image, sniff_format


def _encode(img: Image.Image, fmt: str, **kw) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format=fmt, **kw)
    return buf.getvalue()


@pytest.mark.parametrize("fmt", ["PNG", "JPEG", "GIF", "BMP", "WEBP", "TIFF"])
def test_all_input_formats_decode(fmt):
    img = Image.new("RGB", (32, 24), (10, 200, 30))
    data = _encode(img, fmt)
    assert sniff_format(data) == fmt
    dec = decode_image(data)
    assert dec.rgba.shape == (24, 32, 4)
    assert dec.source_format == fmt
    assert abs(int(dec.rgba[12, 16, 1]) - 200) < 8


def test_alpha_is_preserved():
    img = Image.new("RGBA", (10, 10), (255, 0, 0, 0))
    img.putpixel((5, 5), (0, 0, 255, 128))
    dec = decode_image(_encode(img, "PNG"))
    assert dec.has_alpha
    assert dec.rgba[5, 5, 3] == 128 and dec.rgba[0, 0, 3] == 0


def test_palette_gif_transparency():
    img = Image.new("P", (8, 8), 0)
    img.putpalette([0, 0, 0, 255, 0, 0] + [0] * 762)
    img.putpixel((3, 3), 1)
    data = _encode(img, "GIF", transparency=0)
    dec = decode_image(data)
    assert dec.rgba[0, 0, 3] == 0 and dec.rgba[3, 3, 3] == 255 and dec.rgba[3, 3, 0] == 255


def test_16bit_grayscale_and_cmyk():
    arr = (np.arange(64, dtype=np.uint16).reshape(8, 8) * 1000).astype(np.uint16)
    g16 = Image.fromarray(arr, "I;16")
    dec = decode_image(_encode(g16, "PNG"))
    assert dec.rgba.dtype == np.uint8 and dec.rgba[..., 0].max() > 200
    cmyk = Image.new("CMYK", (8, 8), (0, 255, 255, 0))
    dec = decode_image(_encode(cmyk, "JPEG"))
    assert dec.rgba[4, 4, 0] > 200 and dec.rgba[4, 4, 1] < 60


def test_rejects_unknown_and_corrupt():
    with pytest.raises(ImageDecodeError) as e:
        decode_image(b"<svg xmlns='http://www.w3.org/2000/svg'/>")
    assert e.value.code == "unsupported_format"
    with pytest.raises(ImageDecodeError) as e:
        decode_image(b"\x89PNG\r\n\x1a\n" + b"\x00" * 50)
    assert e.value.code == "corrupt_image"
    with pytest.raises(ImageDecodeError) as e:
        decode_image(b"")
    assert e.value.code == "empty_file"


def test_pixel_limit():
    img = Image.new("RGB", (300, 300))
    with pytest.raises(ImageDecodeError) as e:
        decode_image(_encode(img, "PNG"), max_pixels=10_000)
    assert e.value.code == "too_many_pixels"


def test_file_size_limit():
    with pytest.raises(ImageDecodeError) as e:
        decode_image(b"\x89PNG\r\n\x1a\n" + b"0" * 2000, max_bytes=1000)
    assert e.value.code == "file_too_large"
