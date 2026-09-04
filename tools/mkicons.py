#!/usr/bin/env python3
"""Generate blogd's icon sets with nothing but the standard library.

Writes favicon.svg, favicon.ico (32px PNG-in-ICO), icon-192.png,
icon-512.png and og.png (1200x630) under static/ for the Retro theme,
and the same five files prefixed "sucre-" for the Sucre theme; blogd
serves whichever matches the active theme. Retro is a terminal prompt
on navy in a bevelled frame; Sucre is the same prompt in colonial green
on a whitewashed wall under a terracotta roofline. Re-run after
changing the art; the outputs are committed so a build needs no image
tooling.
"""
import struct, zlib, os

THEMES = {
    # name prefix, background, glyph, frame light/dark (bevel) or
    # roof/line (flat), caption colours
    '': dict(bg=(0x00, 0x00, 0x80), glyph=(0x33, 0xFF, 0x33),
             frame=('bevel', (0xFF, 0xFF, 0xFF), (0x40, 0x40, 0x40)),
             text=(0xFF, 0xFF, 0xFF), text2=(0xC0, 0xC0, 0xC0)),
    'sucre-': dict(bg=(0xFF, 0xFD, 0xF8), glyph=(0x3F, 0x5E, 0x50),
                   frame=('roof', (0xB0, 0x49, 0x2E), (0xE7, 0xDD, 0xCB)),
                   text=(0x33, 0x30, 0x2B), text2=(0xB0, 0x49, 0x2E)),
}

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

    def bevel(self, t, light, dark):
        """Classic outset frame: light top/left, dark bottom/right."""
        self.rect(0, 0, self.w, t, light)
        self.rect(0, 0, t, self.h, light)
        self.rect(0, self.h - t, self.w, self.h, dark)
        self.rect(self.w - t, 0, self.w, self.h, dark)

    def roof(self, t, roof, line):
        """Sucre panel: hairline all round, a thick terracotta roofline."""
        self.rect(0, 0, self.w, max(t // 3, 1), line)
        self.rect(0, 0, max(t // 3, 1), self.h, line)
        self.rect(0, self.h - max(t // 3, 1), self.w, self.h, line)
        self.rect(self.w - max(t // 3, 1), 0, self.w, self.h, line)
        self.rect(0, 0, self.w, t, roof)

    def frame(self, t, spec):
        kind, a, b = spec
        if kind == 'bevel':
            self.bevel(t, a, b)
        else:
            self.roof(t, a, b)

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


def icon(size, th):
    c = Canvas(size, size, th['bg'])
    t = max(size // 16, 1)
    c.frame(t, th['frame'])
    scale = max(size // 12, 1)            # ">_" spans 11 cells
    w = text_width('>_', scale)
    x = (size - w) // 2
    y = (size - 7 * scale) // 2 + (t // 2 if th['frame'][0] == 'roof' else 0)
    c.text('>_', x, y, scale, th['glyph'])
    return c


def og(th):
    W, H = 1200, 630
    c = Canvas(W, H, th['bg'])
    c.frame(12 if th['frame'][0] == 'bevel' else 18, th['frame'])
    # prompt glyph
    s = 28
    c.text('>_', 90, 130, s, th['glyph'])
    # tagline lines
    s2 = 9
    c.text('100% ASM', 90, 400, s2, th['text'])
    c.text('0 BYTES OF JS', 90, 400 + 9 * s2, s2, th['text2'])
    return c


def ico_from_png(png):
    # one 32x32 entry, PNG payload (Vista+ format, all modern browsers)
    hdr = struct.pack('<HHH', 0, 1, 1)
    entry = struct.pack('<BBBBHHII', 32, 32, 0, 0, 1, 32, len(png), 6 + 16)
    return hdr + entry + png


GLYPH = 'M3 3h1v1H3zM4 4h1v1H4zM5 5h1v1H5zM6 6h1v1H6zM5 7h1v1H5zM4 8h1v1H4zM3 9h1v1H3zM8 10h5v1H8z'
SVGS = {
    '': f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#000080"/>
<path d="M0 0h16v1H0zM0 0h1v16H0z" fill="#fff"/>
<path d="M15 0h1v16h-1zM0 15h16v1H0z" fill="#404040"/>
<path fill="#33ff33" d="{GLYPH}"/>
</svg>
''',
    'sucre-': f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#e7ddcb"/>
<rect x="1" y="1" width="14" height="14" fill="#fffdf8"/>
<rect width="16" height="2" fill="#b0492e"/>
<path fill="#3f5e50" d="{GLYPH}"/>
</svg>
''',
}


def main():
    os.makedirs('static', exist_ok=True)
    for prefix, th in THEMES.items():
        p = 'static/' + prefix
        open(p + 'favicon.svg', 'w').write(SVGS[prefix])
        open(p + 'favicon.ico', 'wb').write(ico_from_png(icon(32, th).png()))
        open(p + 'icon-192.png', 'wb').write(icon(192, th).png())
        open(p + 'icon-512.png', 'wb').write(icon(512, th).png())
        open(p + 'og.png', 'wb').write(og(th).png())
        for f in ('favicon.svg', 'favicon.ico', 'icon-192.png', 'icon-512.png', 'og.png'):
            print(f'{prefix}{f}: {os.path.getsize(p + f)} bytes')


if __name__ == '__main__':
    main()
