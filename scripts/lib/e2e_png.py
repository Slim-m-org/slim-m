# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Stdlib PNG reading and pixel diffing for the canvas e2e checks.

Only what a Chrome screenshot needs: non-interlaced, 8-bit grey, RGB or RGBA.
"""
import struct
import zlib

_CHANNELS = {0: 1, 2: 3, 4: 2, 6: 4}


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def _unfilter(raw, height, stride, bpp):
    rows = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        kind = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for i in range(stride):
            left = line[i - bpp] if i >= bpp else 0
            up = prev[i]
            corner = prev[i - bpp] if i >= bpp else 0
            if kind == 1:
                line[i] = (line[i] + left) & 255
            elif kind == 2:
                line[i] = (line[i] + up) & 255
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 255
            elif kind == 4:
                line[i] = (line[i] + _paeth(left, up, corner)) & 255
        rows.append(line)
        prev = line
    return rows


def decode(data):
    """(width, height, rows): each row a bytearray of width * channels bytes."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat = 8, b""
    width = height = channels = None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(
                ">IIBBBBB", body)
            if depth != 8 or interlace or colour not in _CHANNELS:
                raise ValueError("unsupported PNG layout")
            channels = _CHANNELS[colour]
        elif kind == b"IDAT":
            idat += body
    if width is None:
        raise ValueError("PNG has no header")
    rows = _unfilter(zlib.decompress(idat), height, width * channels, channels)
    return width, height, rows, channels


def changed_pixels(before, after, threshold):
    """Every (x, y) whose largest channel differs by more than [threshold]."""
    w1, h1, rows1, ch1 = decode(before)
    w2, h2, rows2, ch2 = decode(after)
    if (w1, h1, ch1) != (w2, h2, ch2):
        raise ValueError("screenshots differ in size")
    out = []
    for y in range(h1):
        a, b = rows1[y], rows2[y]
        if a == b:
            continue
        for x in range(w1):
            i = x * ch1
            if max(abs(a[i + k] - b[i + k]) for k in range(min(ch1, 3))) > threshold:
                out.append((x, y))
    return out
