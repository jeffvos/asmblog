#!/usr/bin/env python3
"""Contrast and type-size floor for the themes in assets/input.css.

Every theme keeps its palette in custom properties on its `.theme-<x>`
scope (and redefines some of them under a prefers-color-scheme media
query). This script resolves those variables for both colour schemes
and checks the pairs that carry small text -- bylines, excerpts,
footers, navigation -- against WCAG AA (4.5:1). It also refuses any
`.meta`/`.byline`/`.footer`/`.navlink` rule that sets a font-size
below the shared floor.

Runs from `make test`; exit status 1 on any failure.
"""
import re
import sys

CSS = "assets/input.css"
MIN_RATIO = 4.5
MIN_META_REM = 0.8125          # 13px at the browser default

# (theme, foreground var, background var, base var for translucent bg)
PAIRS = [
    ("sucre",      "--su-faint", "--su-panel", None),
    ("sucre",      "--su-soft",  "--su-panel", None),
    ("medellin",   "--md-faint", "--md-panel", None),
    ("medellin",   "--md-soft",  "--md-panel", None),
    ("bogota",     "--bo-faint", "--bo-panel", None),
    ("bogota",     "--bo-soft",  "--bo-panel", None),
    ("lapaz",      "--lp-faint", "--lp-panel", None),
    ("lapaz",      "--lp-soft",  "--lp-panel", None),
    ("cochabamba", "--cb-faint", "--cb-card",  None),
    ("cochabamba", "--cb-soft",  "--cb-card",  None),
    ("santacruz",  "--sc-faint", "--sc-panel", "--sc-sand"),
    ("santacruz",  "--sc-soft",  "--sc-panel", "--sc-sand"),
    ("pittsburgh", "--pg-faint", "--pg-plate", None),
    ("pittsburgh", "--pg-soft",  "--pg-plate", None),
]


def parse_color(s):
    s = s.strip()
    m = re.fullmatch(r"#([0-9a-fA-F]{6})", s)
    if m:
        h = m.group(1)
        return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)) + (1.0,)
    m = re.fullmatch(r"#([0-9a-fA-F]{3})", s)
    if m:
        h = m.group(1)
        return tuple(int(c * 2, 16) / 255 for c in h) + (1.0,)
    m = re.fullmatch(r"rgba?\(([^)]*)\)", s)
    if m:
        parts = [p.strip() for p in m.group(1).split(",")]
        rgb = tuple(float(p) / 255 for p in parts[:3])
        a = float(parts[3]) if len(parts) > 3 else 1.0
        return rgb + (a,)
    raise ValueError("unparsed colour: %r" % s)


def composite(fg, bg):
    a = fg[3]
    return tuple(fg[i] * a + bg[i] * (1 - a) for i in range(3)) + (1.0,)


def luminance(c):
    def lin(v):
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in c[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    x, y = luminance(a), luminance(b)
    hi, lo = max(x, y), min(x, y)
    return (hi + 0.05) / (lo + 0.05)


def blocks(css):
    """Yield (selector, body, scheme) for every rule in the sheet, with
    scheme = 'light' | 'dark' | None for rules inside a prefers-color-
    scheme media query (or not)."""
    i = 0
    n = len(css)
    stack = []                  # media-query schemes
    while i < n:
        j = css.find("{", i)
        if j < 0:
            return
        head = css[i:j].strip()
        head = re.sub(r"/\*.*?\*/", "", head, flags=re.S).strip()
        if head.startswith("@media"):
            m = re.search(r"prefers-color-scheme:\s*(light|dark)", head)
            stack.append(m.group(1) if m else None)
            i = j + 1
            continue
        if head.startswith("@"):
            # other at-rules (@import, @view-transition, @keyframes):
            # skip the balanced body
            depth = 0
            k = j
            while k < n:
                if css[k] == "{":
                    depth += 1
                elif css[k] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            i = k + 1
            continue
        k = css.find("}", j)
        body = css[j + 1:k]
        yield head, body, (stack[-1] if stack else None)
        i = k + 1
        # pop closed media blocks
        while stack and i < n and css[i:].lstrip().startswith("}"):
            i = css.find("}", i) + 1
            stack.pop()


def main():
    css = open(CSS, encoding="utf-8").read()
    default = {}                # theme -> {var: value}
    schemed = {}                # (theme, scheme) -> {var: value}
    sizes = []                  # (selector, rem, scheme)
    for sel, body, scheme in blocks(css):
        for tsel in [s.strip() for s in sel.split(",")]:
            m = re.match(r"\.theme-([a-z]+)\s*$", tsel)
            if m:
                theme = m.group(1)
                d = schemed.setdefault((theme, scheme), {}) if scheme else default.setdefault(theme, {})
                for vm in re.finditer(r"(--[a-z0-9-]+)\s*:\s*([^;]+);", body):
                    d[vm.group(1)] = re.sub(r"/\*.*?\*/", "", vm.group(2)).strip()
            if re.search(r"\.(meta|byline|footer|navlink)\b", tsel) and not re.search(r"::|:hover|\.footer\s*>|\.footer ", tsel):
                fm = re.search(r"font-size\s*:\s*([0-9.]+)(rem|px)", body)
                if fm:
                    v = float(fm.group(1))
                    rem = v if fm.group(2) == "rem" else v / 16
                    sizes.append((tsel, rem))

    failures = 0
    for theme, fg, bg, base in PAIRS:
        for scheme in ("light", "dark"):
            vars_ = dict(default.get(theme, {}))
            vars_.update(schemed.get((theme, scheme), {}))
            try:
                fgc = parse_color(vars_[fg])
                bgc = parse_color(vars_[bg])
                if bgc[3] < 1.0:
                    bgc = composite(bgc, parse_color(vars_[base]))
            except KeyError as e:
                print("skip %-10s %-5s %s: missing %s" % (theme, scheme, fg, e))
                continue
            r = ratio(fgc, bgc)
            ok = r >= MIN_RATIO
            failures += not ok
            print("%s %-10s %-5s %-12s on %-12s %5.2f:1" % ("ok  " if ok else "FAIL", theme, scheme, fg, bg, r))
    for sel, rem in sizes:
        ok = rem >= MIN_META_REM - 1e-9
        failures += not ok
        print("%s %-40s font-size %.4frem (%.1fpx)" % ("ok  " if ok else "FAIL", sel, rem, rem * 16))
    if failures:
        print("contrast: %d failure(s)" % failures)
        sys.exit(1)
    print("contrast: all checks passed")


if __name__ == "__main__":
    main()
