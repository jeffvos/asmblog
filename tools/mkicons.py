#!/usr/bin/env python3
"""Generate blogd's icon sets with nothing but the standard library.

Writes favicon.svg, favicon.ico (32px PNG-in-ICO), icon-192.png,
icon-512.png and og.png (1200x630) under static/ for the Retro theme,
and the same five files prefixed "<theme>-" for every other theme
(sucre-, medellin-, bogota-, lapaz-, cochabamba-, santacruz-); blogd
serves whichever matches the active theme. Each set carries its
theme's own frame: Retro is a terminal prompt on navy in a bevelled
frame; Sucre a whitewashed wall under a terracotta roofline; Medellín a
poster with an ink outline over a band of flowers; Bogotá a gold plaque
on a brick wall; La Paz a stepped, aguayo-topped cholet facade;
Cochabamba a chalkboard in a wooden frame on kraft paper; Santa Cruz a
sand square over painted mission woodwork; Pittsburgh a riveted steel
plate under a gold bridge truss. Re-run after changing the
art; the outputs are committed so a build needs no image tooling.
"""
import struct, zlib, os


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


THEMES = {
    # prefix -> background, glyph, frame spec (kind + colours), caption colours
    '': dict(bg=rgb('#000080'), glyph=rgb('#33ff33'),
             frame=('bevel', rgb('#ffffff'), rgb('#404040')),
             text=rgb('#ffffff'), text2=rgb('#c0c0c0')),
    'sucre-': dict(bg=rgb('#fffdf8'), glyph=rgb('#3f5e50'),
                   frame=('roof', rgb('#b0492e'), rgb('#e7ddcb')),
                   text=rgb('#33302b'), text2=rgb('#b0492e')),
    'medellin-': dict(bg=rgb('#ffffff'), glyph=rgb('#1f7a3e'),
                      frame=('poster', rgb('#14161a'),
                             [rgb(c) for c in ('#e4327b', '#f7c948', '#f0742e', '#1f7a3e', '#7b3fa0')]),
                      text=rgb('#14161a'), text2=rgb('#e4327b')),
    'bogota-': dict(bg=rgb('#7b3f33'), glyph=rgb('#c9a03e'),
                    frame=('brick', rgb('#4d2a22'), rgb('#c9a03e')),
                    text=rgb('#ece7dc'), text2=rgb('#c9a03e')),
    'lapaz-': dict(bg=rgb('#221a2e'), glyph=rgb('#ffb000'),
                   frame=('steps', rgb('#17111f'), rgb('#17a398'),
                          [rgb(c) for c in ('#e0313f', '#ff7a1a', '#ffb000', '#35b24a', '#3fb8ff', '#8a3fc9', '#ff3fa4')]),
                   text=rgb('#f2ecf7'), text2=rgb('#5fd3c8')),
    'cochabamba-': dict(bg=rgb('#2f3a3d'), glyph=rgb('#f3efe6'),
                        frame=('chalk', rgb('#dcc39b'), rgb('#8b5a2b')),
                        text=rgb('#f3efe6'), text2=rgb('#e9b427')),
    'santacruz-': dict(bg=rgb('#fbf8f1'), glyph=rgb('#177245'),
                       frame=('mission', [rgb(c) for c in ('#c98a2c', '#a73a2a', '#0f4d33', '#f1dcb0')]),
                       text=rgb('#0f4d33'), text2=rgb('#ff6f59')),
    'pittsburgh-': dict(bg=rgb('#2a2e33'), glyph=rgb('#ffb81c'),
                        frame=('steel', rgb('#101214'), rgb('#ffb81c'), rgb('#9aa0a6')),
                        text=rgb('#f2f0ea'), text2=rgb('#ffb81c')),
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

    def poster(self, t, ink, stripes):
        """Medellín: thick ink outline, a band of flowers along the foot."""
        band = t * 2
        n = len(stripes)
        seg = max(self.w // (n * 2), 1)
        for x in range(0, self.w, seg):
            self.rect(x, self.h - band - t, x + seg, self.h - t, stripes[(x // seg) % n])
        self.rect(0, self.h - band - 2 * t, self.w, self.h - band - t, ink)
        self.rect(0, 0, self.w, t, ink)
        self.rect(0, 0, t, self.h, ink)
        self.rect(0, self.h - t, self.w, self.h, ink)
        self.rect(self.w - t, 0, self.w, self.h, ink)

    def brick(self, t, mortar, gold):
        """Bogotá: running-bond courses over the wall, a gold hairline."""
        course = max(self.h // 9, 4)
        m = max(course // 8, 1)
        length = course * 2
        for row, y in enumerate(range(0, self.h, course)):
            self.rect(0, y, self.w, y + m, mortar)
            off = (length // 2) if row % 2 else 0
            for x in range(off, self.w + length, length):
                self.rect(x, y, x + m, y + course, mortar)
        g = max(t // 3, 1)
        self.rect(0, 0, self.w, g, gold)
        self.rect(0, 0, g, self.h, gold)
        self.rect(0, self.h - g, self.w, self.h, gold)
        self.rect(self.w - g, 0, self.w, self.h, gold)

    def steps(self, t, night, stroke, stripes):
        """La Paz: a stepped-corner stroke around the panel, aguayo on top."""
        s = max(self.w // 8, 2)              # step size
        panel = [list(p) for p in self.px[:1]][0]
        bg = self.px[0][:]                    # panel colour set at creation
        self.rect(0, 0, self.w, self.h, night)
        # stroke, then the face inset by t, both with stepped corners
        def stepped(x0, y0, x1, y1, c, st):
            self.rect(x0 + st, y0, x1 - st, y1, c)
            self.rect(x0, y0 + st, x1, y1 - st, c)
            self.rect(x0 + st // 2, y0 + st // 2, x1 - st // 2, y1 - st // 2, c)
        stepped(0, 0, self.w, self.h, stroke, 2 * s)
        stepped(t, t, self.w - t, self.h - t, bg, 2 * s)
        # aguayo band across the top of the face
        n = len(stripes)
        seg = max(self.w // 14, 1)
        x0, x1 = t + 2 * s, self.w - t - 2 * s
        for x in range(x0, x1, seg):
            self.rect(x, t, min(x + seg, x1), t + max(t // 2, 1) + t // 2 + 1, stripes[(x // seg) % n])

    def chalk(self, t, kraft, wood):
        """Cochabamba: kraft margin, wooden frame, the board inside."""
        board = self.px[0][:]
        self.rect(0, 0, self.w, self.h, kraft)
        self.rect(t, t, self.w - t, self.h - t, wood)
        w = max(t, 2)
        self.rect(t + w, t + w, self.w - t - w, self.h - t - w, board)

    def mission(self, t, stripes):
        """Santa Cruz: painted diagonal woodwork along the foot."""
        band = max(t * 2, 3)
        n = len(stripes)
        w = max(self.w // 20, 2)
        for y in range(self.h - band, self.h):
            for x in range(self.w):
                self.px[y * self.w + x] = list(stripes[((x + y) // w) % n])

    def line(self, x0, y0, x1, y1, w, c):
        """A w-thick line of squares (enough for pixel-art diagonals)."""
        n = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(n + 1):
            x = x0 + (x1 - x0) * i // n
            y = y0 + (y1 - y0) * i // n
            self.rect(x - w // 2, y - w // 2, x - w // 2 + w, y - w // 2 + w, c)

    def steel(self, t, black, gold, rivet):
        """Pittsburgh: a bridge truss across the top, gold hairline, rivets."""
        band = t * 2
        self.rect(0, 0, self.w, band, black)
        w = max(t // 3, 1)
        step = band
        x = 0
        while x < self.w:
            self.line(x, band - w, x + step, w, w, gold)
            self.line(x + step, w, x + 2 * step, band - w, w, gold)
            x += 2 * step
        self.rect(0, 0, self.w, w, gold)
        self.rect(0, band - w, self.w, band, gold)
        self.rect(0, self.h - w, self.w, self.h, gold)
        self.rect(0, 0, w, self.h, gold)
        self.rect(self.w - w, 0, self.w, self.h, gold)
        r = max(t // 2, 2)
        m = t + w
        for (x, y) in ((m, band + m), (self.w - m - r, band + m),
                       (m, self.h - m - r), (self.w - m - r, self.h - m - r)):
            self.rect(x, y, x + r, y + r, rivet)

    def frame(self, t, spec):
        kind = spec[0]
        if kind == 'bevel':
            self.bevel(t, spec[1], spec[2])
        elif kind == 'roof':
            self.roof(t, spec[1], spec[2])
        elif kind == 'poster':
            self.poster(t, spec[1], spec[2])
        elif kind == 'brick':
            self.brick(t, spec[1], spec[2])
        elif kind == 'steps':
            self.steps(t, spec[1], spec[2], spec[3])
        elif kind == 'chalk':
            self.chalk(t, spec[1], spec[2])
        elif kind == 'mission':
            self.mission(t, spec[1])
        elif kind == 'steel':
            self.steel(t, spec[1], spec[2], spec[3])

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
    kind = th['frame'][0]
    # ">_" spans 11 cells; framed themes leave room for the frame
    scale = max(size // (15 if kind in ('steps', 'chalk', 'brick', 'steel') else 12), 1)
    w = text_width('>_', scale)
    x = (size - w) // 2
    y = (size - 7 * scale) // 2
    if kind == 'roof':
        y += t // 2
    elif kind in ('poster', 'mission'):
        y -= t                            # room for the band at the foot
    elif kind == 'steps':
        y += t // 2
    elif kind == 'steel':
        y += t                            # below the truss band
    c.text('>_', x, y, scale, th['glyph'])
    return c


def og(th):
    W, H = 1200, 630
    c = Canvas(W, H, th['bg'])
    c.frame(12 if th['frame'][0] == 'bevel' else 18, th['frame'])
    if th['frame'][0] == 'brick':          # a plaque to write on
        c.rect(60, 90, 830, 580, rgb('#26292d'))
        c.rect(60, 90, 830, 93, rgb('#c9a03e'))
        c.rect(60, 577, 830, 580, rgb('#c9a03e'))
        c.rect(60, 90, 63, 580, rgb('#c9a03e'))
        c.rect(827, 90, 830, 580, rgb('#c9a03e'))
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
    # Medellín: ink outline, flower band along the foot
    'medellin-': f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#14161a"/>
<rect x="1" y="1" width="14" height="14" fill="#fff"/>
<path d="M1 12h3v3H1z" fill="#e4327b"/><path d="M4 12h3v3H4z" fill="#f7c948"/><path d="M7 12h3v3H7z" fill="#f0742e"/><path d="M10 12h3v3h-3z" fill="#1f7a3e"/><path d="M13 12h2v3h-2z" fill="#7b3fa0"/>
<rect x="1" y="11" width="14" height="1" fill="#14161a"/>
<path fill="#1f7a3e" d="{GLYPH}"/>
</svg>
''',
    # Bogotá: brick courses, a gold hairline, gold prompt
    'bogota-': f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#7b3f33"/>
<path d="M0 3h16v1H0zM0 7h16v1H0zM0 11h16v1H0zM0 15h16v1H0zM7 0h1v3H7zM3 4h1v3H3zM11 4h1v3h-1zM7 8h1v3H7zM3 12h1v3H3zM11 12h1v3h-1z" fill="#4d2a22"/>
<path d="M0 0h16v1H0zM0 15h16v1H0zM0 0h1v16H0zM15 0h1v16h-1z" fill="#c9a03e"/>
<path fill="#c9a03e" d="{GLYPH}"/>
</svg>
''',
    # La Paz: stepped corners, teal stroke, aguayo along the top
    'lapaz-': f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#17111f"/>
<path d="M4 0h8v2h2v2h2v8h-2v2h-2v2H4v-2H2v-2H0V4h2V2h2z" fill="#17a398"/>
<path d="M5 1h6v2h2v2h2v6h-2v2h-2v2H5v-2H3v-2H1V5h2V3h2z" fill="#221a2e"/>
<path d="M5 1h2v1H5z" fill="#e0313f"/><path d="M7 1h2v1H7z" fill="#ffb000"/><path d="M9 1h2v1H9z" fill="#35b24a"/><path d="M11 1h1v1h-1z" fill="#3fb8ff"/>
<path fill="#ffb000" d="{GLYPH}"/>
</svg>
''',
    # Cochabamba: kraft margin, wooden frame, chalk on slate
    'cochabamba-': f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#dcc39b"/>
<rect x="1" y="1" width="14" height="14" fill="#8b5a2b"/>
<rect x="2" y="2" width="12" height="12" fill="#2f3a3d"/>
<path fill="#f3efe6" d="{GLYPH}"/>
</svg>
''',
    # Pittsburgh: steel plate, gold hairline, rivets, truss along the foot
    'pittsburgh-': f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#2a2e33"/>
<path d="M0 0h16v1H0zM0 15h16v1H0zM0 0h1v16H0zM15 0h1v16h-1z" fill="#ffb81c"/>
<path d="M1 12h14v3H1z" fill="#101214"/>
<path d="M1 14h1v-1h1v-1h1v1h1v1h1v-1h1v-1h1v1h1v1h1v-1h1v-1h1v1h1v1h1v1H1z" fill="#ffb81c"/>
<path d="M2 2h1v1H2zM13 2h1v1h-1z" fill="#9aa0a6"/>
<path fill="#ffb81c" d="{GLYPH}"/>
</svg>
''',
    # Santa Cruz: sand, painted mission woodwork along the foot
    'santacruz-': f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">
<rect width="16" height="16" fill="#fbf8f1"/>
<path d="M0 12h16v4H0z" fill="#f1dcb0"/>
<path d="M0 12h2l4 4H2zM8 12h2l4 4h-2z" fill="#c98a2c"/><path d="M2 12h2l4 4H4zM10 12h2l4 4h-2z" fill="#a73a2a"/><path d="M4 12h2l4 4H6zM12 12h2l2 2v2h-1z" fill="#0f4d33"/>
<path fill="#177245" d="{GLYPH}"/>
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
