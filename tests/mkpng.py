#!/usr/bin/env python3
"""Write a test PNG to stdout using only the standard library.

    mkpng.py WIDTH HEIGHT [seed] [noisy]

A smooth colour gradient with a diagonal stripe, so a resized copy is
still recognisably the same picture. Rows use the PNG "Up" filter, so
the plain picture compresses to a few KB (an upload that fits the
request buffer); "noisy" adds per-pixel noise that does not compress,
for an upload that has to stream to disk. Used by the test suite and
the Docker build test, which must not depend on Pillow.
"""
import struct
import sys
import zlib


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def main():
    w, h = int(sys.argv[1]), int(sys.argv[2])
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 7
    noisy = len(sys.argv) > 4 and sys.argv[4] == "noisy"
    rows = bytearray()
    prev = bytes(3 * w)
    state = seed * 2654435761 & 0xFFFFFFFF
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r = (x * 255) // max(w - 1, 1)
            g = (y * 255) // max(h - 1, 1)
            b = (seed * 37 + y * 3) & 0xFF
            if abs((x * h) - (y * w)) < 6 * max(w, h):
                r, g, b = 255 - r, 255 - g, 255 - b
            if noisy:
                state = (state * 1103515245 + 12345) & 0xFFFFFFFF
                n = state >> 24
                r, g, b = (r + n) & 0xFF, (g + (n >> 1)) & 0xFF, (b ^ n) & 0xFF
            row += bytes((r, g, b))
        rows.append(2)                       # filter: Up
        rows += bytes((row[i] - prev[i]) & 0xFF for i in range(3 * w))
        prev = bytes(row)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 6))
    png += chunk(b"IEND", b"")
    sys.stdout.buffer.write(png)


if __name__ == "__main__":
    main()
