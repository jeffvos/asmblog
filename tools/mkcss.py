#!/usr/bin/env python3
"""Build one stylesheet per theme from assets/input.css.

input.css is authored as one file: a shared prelude (the Tailwind
import, layout, view transitions) followed by one `THEME: <NAME>`
section per theme. Serving all eight sections to every visitor would
mean ~70 KB of render-blocking CSS for a page that uses one theme, so
this script splits the sheet at the section banners, runs the Tailwind
CLI once per theme, and writes:

    static/main.css                 (retro, the default theme)
    static/<theme>-main.css         (every other theme)

plus .gz and .br siblings of each (the server negotiates them). blogd
serves /static/main.css from whichever file matches the active theme,
the same way it swaps the themed icons.

brotli is required: production clients overwhelmingly accept it, and a
silently missing .br would only show up as slower pages. Set
BLOGD_NO_BROTLI=1 to build without it on a machine that lacks the CLI.
"""
import gzip
import os
import re
import shutil
import subprocess
import sys

SRC = "assets/input.css"
OUT = "static"
TMP = "build/css"
TAILWIND = "tools/tailwindcss"

# theme id order matches pages.asm's theme table; retro is main.css
THEMES = ["retro", "sucre", "medellin", "bogota", "lapaz",
          "cochabamba", "santacruz", "pittsburgh"]
BANNER = {
    "retro": "RETRO", "sucre": "SUCRE", "medellin": "MEDELLÍN",
    "bogota": "BOGOTÁ", "lapaz": "LA PAZ", "cochabamba": "COCHABAMBA",
    "santacruz": "SANTA CRUZ", "pittsburgh": "PITTSBURGH",
}


def out_name(theme):
    return "main.css" if theme == "retro" else theme + "-main.css"


SHARED = "/* ===== shared bits ===== */"


def split(css):
    """-> (prelude, {theme: section}, trailer) by the 'THEME: NAME'
    banners; the trailer is everything from the SHARED marker on (rules
    every theme needs: bylines, marquee keyframes, figures, print)."""
    # a section banner is the comment block that names the theme; the
    # block starts at the '/* ====' line before it
    starts = []
    for m in re.finditer(r"/\* =+\n\s*THEME: ([A-ZÍÁ ]+?)\s+[—-]", css):
        starts.append((m.start(), m.group(1).strip()))
    if len(starts) != len(THEMES):
        sys.exit("mkcss: expected %d THEME sections, found %d" % (len(THEMES), len(starts)))
    shared = css.find(SHARED)
    if shared < 0 or shared < starts[-1][0]:
        sys.exit("mkcss: the %r marker must follow the last THEME section" % SHARED)
    prelude = css[:starts[0][0]]
    trailer = css[shared:]
    sections = {}
    for i, (pos, name) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else shared
        theme = next((t for t in THEMES if BANNER[t] == name or name.startswith(BANNER[t])), None)
        if theme is None:
            sys.exit("mkcss: unknown theme section %r" % name)
        sections[theme] = css[pos:end]
    missing = [t for t in THEMES if t not in sections]
    if missing:
        sys.exit("mkcss: no section for %s" % ", ".join(missing))
    return prelude, sections, trailer


def main():
    if not os.access(TAILWIND, os.X_OK):
        sys.exit("mkcss: %s missing (download the Tailwind standalone CLI, see README)" % TAILWIND)
    brotli = shutil.which("brotli")
    if not brotli and os.environ.get("BLOGD_NO_BROTLI") != "1":
        sys.exit("mkcss: the brotli CLI is required (apt install brotli / apk add brotli); "
                 "set BLOGD_NO_BROTLI=1 to build without .br siblings")
    css = open(SRC, encoding="utf-8").read()
    prelude, sections, trailer = split(css)
    os.makedirs(TMP, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    for theme in THEMES:
        src = os.path.join(TMP, theme + ".css")
        with open(src, "w", encoding="utf-8") as f:
            f.write(prelude)
            f.write(sections[theme])
            f.write(trailer)
        dst = os.path.join(OUT, out_name(theme))
        subprocess.run([TAILWIND, "-i", src, "-o", dst, "--minify"], check=True)
        data = open(dst, "rb").read()
        with open(dst + ".gz", "wb") as f:
            f.write(gzip.compress(data, compresslevel=9, mtime=0))
        if brotli:
            subprocess.run([brotli, "-kf", "-q", "11", dst], check=True)
        elif os.path.exists(dst + ".br"):
            os.remove(dst + ".br")
        print("%-24s %6d bytes, %5d gz%s" % (
            dst, len(data), os.path.getsize(dst + ".gz"),
            (", %5d br" % os.path.getsize(dst + ".br")) if brotli else ""))


if __name__ == "__main__":
    main()
