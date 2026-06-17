"""Shared test helpers — zero third-party dependencies (stdlib only).

Two jobs:
  1. load_agent_server()  — import the builder's agent server, which lives as a
     hyphenated, heredoc-baked file (~/.local-llm-setup/agent-server.py). We import
     the dogfooded source of truth; tools/bake.py guarantees the installers embed it
     verbatim, and test_bake.py asserts that invariant.
  2. decode_png()         — a tiny pure-Python PNG reader so the screenshot tests can
     assert real pixel content (valid PNG, exact dimensions, not blank) without Pillow.
"""
import os, sys, zlib, struct, importlib.util

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_SERVER_PATH = os.path.join(os.path.expanduser("~"), ".local-llm-setup", "agent-server.py")


def load_agent_server():
    """Import ~/.local-llm-setup/agent-server.py as a module (handles the hyphen)."""
    spec = importlib.util.spec_from_file_location("agent_server", AGENT_SERVER_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)   # safe: the server only binds a socket under __main__
    return mod


# ---------------- minimal PNG decoder (stdlib only) ----------------
def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc: return a
    if pb <= pc: return b
    return c


class PNG:
    def __init__(self, width, height, channels, pixels):
        self.width = width
        self.height = height
        self.channels = channels        # 3 (RGB) or 4 (RGBA)
        self.pixels = pixels            # bytes, row-major, `channels` per pixel

    def rgb(self, x, y):
        i = (y * self.width + x) * self.channels
        return (self.pixels[i], self.pixels[i + 1], self.pixels[i + 2])

    def is_all_white(self, thresh=250):
        px, c = self.pixels, self.channels
        for i in range(0, len(px), c):
            if px[i] < thresh or px[i + 1] < thresh or px[i + 2] < thresh:
                return False
        return True

    def fraction_matching(self, rgb, tol=40):
        """Fraction of pixels within `tol` (per channel) of the target colour."""
        r0, g0, b0 = rgb
        px, c = self.pixels, self.channels
        total = self.width * self.height
        hit = 0
        for i in range(0, len(px), c):
            if abs(px[i] - r0) <= tol and abs(px[i + 1] - g0) <= tol and abs(px[i + 2] - b0) <= tol:
                hit += 1
        return hit / total if total else 0.0


def decode_png(data):
    """Decode 8-bit PNG (colour types 2/6, and 0/4 expanded to RGB) to a PNG object."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG (bad signature)")
    pos = 8
    width = height = bit_depth = color_type = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length            # 4 len + 4 type + data + 4 crc
        if ctype == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
    if bit_depth != 8:
        raise ValueError(f"unsupported bit depth {bit_depth} (expected 8)")
    src_channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if src_channels is None:
        raise ValueError(f"unsupported colour type {color_type}")

    raw = zlib.decompress(bytes(idat))
    stride = width * src_channels
    out = bytearray(stride * height)
    prev = bytearray(stride)
    rp = 0
    for y in range(height):
        ftype = raw[rp]; rp += 1
        row = bytearray(raw[rp:rp + stride]); rp += stride
        bpp = src_channels
        if ftype == 1:      # Sub
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif ftype == 2:    # Up
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif ftype == 3:    # Average
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:    # Paeth
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + _paeth(a, prev[i], c)) & 0xFF
        elif ftype != 0:
            raise ValueError(f"unsupported PNG filter {ftype}")
        out[y * stride:(y + 1) * stride] = row
        prev = row

    # normalise to RGB(A) -> always expose at least 3 channels
    if src_channels in (3, 4):
        return PNG(width, height, src_channels, bytes(out))
    # grayscale (1) or grayscale+alpha (2) -> expand to RGB
    rgb = bytearray(width * height * 3)
    for p in range(width * height):
        g = out[p * src_channels]
        rgb[p * 3] = rgb[p * 3 + 1] = rgb[p * 3 + 2] = g
    return PNG(width, height, 3, bytes(rgb))
