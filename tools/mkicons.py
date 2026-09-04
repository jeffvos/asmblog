#!/usr/bin/env python3
"""Generate blogd's icon set with nothing but the standard library.

Writes static/favicon.svg, static/favicon.ico (32px PNG-in-ICO),
static/icon-192.png, static/icon-512.png and static/og.png (1200x630):
a retro terminal prompt on navy with a bevelled frame and 5x7 pixel
text. Re-run after changing the art; the outputs are committed so a
build needs no image tooling.
"""
import struct, zlib, os

NAVY = (0x00, 0x00, 0x80)
GREEN = (0x33, 0xFF, 0x33)
LIGHT = (0xFF, 0xFF, 0xFF)
DARK = (0x40, 0x40, 0x40)
SILVER = (0xC0, 0xC0, 0xC0)

# 5x7 pixel font for the glyphs we print
FONT = {
    '0': ["01110","10001","10011","10101","11001","10001","01110"],
    '1': ["00100","01100","00100","00100","00100","00100","01110"],
    '2': ["01110","10001","00001","00010","00100","01000","11111"],
    '3': ["11111","00010","00100","00010","00001","10001","01110"],
    '4': ["00010","00110","01010","10010","11111","00010","00010"],
    '5': ["11111","10000","11110","00001","00001","10001","01110"],
    '6': ["00110","01000","10000","11110","10001","10001","01110"],
    '7': ["11111","00001","00010","00100","01000","01000","01000"],
    '8': ["01110","10001","10001","01110","10001","10001","01110"],
    '9': ["01110","10001","10001","01111","00001","00010","01100"],
    'A': ["01110","10001","10001","11111","10001","10001","10001"],
    'B': ["11110","10001","10001","11110","10001","10001","11110"],
    'D': ["11110","10001","10001","10001","10001","10001","11110"],
    'E': ["11111","10000","10000","11110","10000","10000","11111"],
    'F': ["11111","10000","10000","11110","10000","10000","10000"],
    'G': ["01110","10001","10000","10111","10001","10001","01111"],
    'J': ["00111","00010","00010","00010","00010","10010","01100"],
    'L': ["10000","10000","10000","10000","10000","10000","11111"],
    'M': ["10001","11011","10101","10101","10001","10001","10001"],
    'O': ["01110","10001","10001","10001","10001","10001","01110"],
    'S': ["01111","10000","10000","01110","00001","00001","11110"],
    'T': ["11111","00100","00100","00100","00100","00100","00100"],
    'Y': ["10001","10001","01010","00100","00100","00100","00100"],
    '%': ["11001","11010","00010","00100","01000","01011","10011"],
    ' ': ["00000"]*7,
    '>': ["10000","01000","00100","00010","00100","01000","10000"],
    '_': ["00000","00000","00000","00000","00000","00000","11111"],
}


class Canvas:
    def __init__(self, w, h, bg):
        self.w, self.h = w, h
        self.px = [list(bg) for _ in range(w * h)]

    def rect(self, x0, y0, x1, y1, c):
        for y in range(max(y0, 0), min(y1, self.h)):
            row = y * self.w
            for x in range(max(x0, 0), min(x1, self.w)):
                self.px[row + x] = list(c)

    def bevel(self, t):
        """Classic outset frame: light top/left, dark bottom/right."""
        self.rect(0, 0, self.w, t, LIGHT)
        self.rect(0, 0, t, self.h, LIGHT)
        self.rect(0, self.h - t, self.w, self.h, DARK)
        self.rect(self.w - t, 0, self.w, self.h, DARK)

    def text(self, s, x, y, scale, c):
        for ch in s:
            g = FONT[ch]
            for r, row in enumerate(g):
                for col, bit in enumerate(row):
                    if bit == '1':
                        self.rect(x + col * scale, y + r * scale,
                                  x + (col + 1) * scale, y + (r + 1) * scale, c)
            x += 6 * scale
        return x

    def png(self):
        raw = b''.join(b'\x00' + bytes(v for p in self.px[y*self.w:(y+1)*self.w] for v in p)
                       for y in range(self.h))
        def chunk(t, d):
            return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
        return (b'\x89PNG\r\n\x1a\n'
                + chunk(b'IHDR', struct.pack('>IIBBBBB', self.w, self.h, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9))
                + chunk(b'IEND', b''))


def text_width(s, scale):
    return len(s) * 6 * scale - scale


def icon(size):
    c = Canvas(size, size, NAVY)
    t = max(size // 16, 1)
    c.bevel(t)
    scale = max(size // 12, 1)            # ">_" spans 11 cells
    w = text_width('>_', scale)
    x = (size - w) // 2
    y = (size - 7 * scale) // 2
    c.text('>_', x, y, scale, GREEN)
    return c


def og():
    W, H = 1200, 630
    c = Canvas(W, H, NAVY)
    c.bevel(12)
    # prompt glyph
    s = 28
    c.text('>_', 90, 130, s, GREEN)
    # tagline lines
    s2 = 9
    c.text('100% ASM', 90, 400, s2, LIGHT)
    c.text('0 BYTES OF JS', 90, 400 + 9 * s2, s2, SILVER)
    return c


def ico_from_png(png):
    # one 32x32 entry, PNG payload (Vista+ format, all modern browsers)
    hdr = struct.pack('<HHH', 0, 1, 1)
    entry = struct.pack('<BBBBHHII', 32, 32, 0, 0, 1, 32, len(png), 6 + 16)
    return hdr + entry + png


SVG = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#000080"/>
<path d="M0 0h16v1H0zM0 0h1v16H0z" fill="#fff"/>
<path d="M15 0h1v16h-1zM0 15h16v1H0z" fill="#404040"/>
<path fill="#33ff33" d="M3 3h1v1H3zM4 4h1v1H4zM5 5h1v1H5zM6 6h1v1H6zM5 7h1v1H5zM4 8h1v1H4zM3 9h1v1H3zM8 10h5v1H8z"/>
</svg>
'''


def main():
    os.makedirs('static', exist_ok=True)
    open('static/favicon.svg', 'w').write(SVG)
    open('static/favicon.ico', 'wb').write(ico_from_png(icon(32).png()))
    open('static/icon-192.png', 'wb').write(icon(192).png())
    open('static/icon-512.png', 'wb').write(icon(512).png())
    open('static/og.png', 'wb').write(og().png())
    for f in ('favicon.svg', 'favicon.ico', 'icon-192.png', 'icon-512.png', 'og.png'):
        print(f'{f}: {os.path.getsize("static/" + f)} bytes')


if __name__ == '__main__':
    main()
