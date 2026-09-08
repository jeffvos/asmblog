#!/usr/bin/env python3
"""Contrast and type-size floor for the themes in assets/input.css.

Every theme keeps its palette in custom properties on its `.theme-<x>`
scope (and redefines some of them under a prefers-color-scheme media
query). This script resolves those variables -- following var()
references -- for both colour schemes and checks:

  * the pairs that carry small public text (bylines, excerpts, footers,
    navigation) against WCAG AA (4.5:1);
  * the admin tokens (--a-*) every theme must define, against the
    admin card (--a-panel): error/delete text, the draft badge, links,
    help text and the secondary button's text at 4.5:1; button text on
    the button fills and field text on the field background at 4.5:1;
    the focus ring and the field border against the card at 3:1
    (the non-text minimum);
  * any `.meta`/`.byline`/`.footer`/`.navlink` rule that sets a
    font-size below the shared floor.

Runs from `make test`; exit status 1 on any failure.
"""
import re
import sys

CSS = "assets/input.css"
MIN_RATIO = 4.5
MIN_UI_RATIO = 3.0             # non-text contrast (WCAG 1.4.11)
MIN_META_REM = 0.8125          # 13px at the browser default

THEMES = ["retro", "sucre", "medellin", "bogota", "lapaz",
          "cochabamba", "santacruz", "pittsburgh"]

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

# admin tokens: small text on the admin card
ADMIN_TEXT = ["--a-danger", "--a-draft", "--a-link", "--a-hint", "--a-accent"]
# admin tokens: text on a fill (foreground, background)
ADMIN_FILL = [("--a-accent-ink", "--a-accent"),
              ("--a-danger-ink", "--a-danger"),
              ("--a-field-ink",  "--a-field-bg")]
# admin tokens: non-text against the card
ADMIN_UI = ["--a-focus", "--a-field-line"]
# the card(s) the admin tokens are checked against; Pittsburgh's plate
# is a gradient between two greys, so both ends count
ADMIN_PANELS = {t: ["--a-panel"] for t in THEMES}
ADMIN_PANELS["pittsburgh"] = ["--pg-plate", "--pg-plate2"]
# what a translucent card composites over
PAGE_BASE = {"santacruz": "--sc-sand"}


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


def resolve(vars_, name, depth=0):
    """The colour a custom property resolves to, following var() links."""
    if depth > 16:
        raise ValueError("var() cycle at %s" % name)
    v = vars_[name]
    m = re.fullmatch(r"var\((--[a-z0-9-]+)\)", v.strip())
    if m:
        return resolve(vars_, m.group(1), depth + 1)
    return parse_color(v)


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

    def report(ok, theme, scheme, fg, bg, r, floor):
        print("%s %-10s %-5s %-14s on %-12s %5.2f:1 (min %.1f)" % (
            "ok  " if ok else "FAIL", theme, scheme, fg, bg, r, floor))
        return 0 if ok else 1

    def solid(vars_, theme, name, under=()):
        """The var as an opaque colour: a translucent value composites
        over the first of `under` that exists (then the page base)."""
        c = resolve(vars_, name)
        if c[3] < 1.0:
            for u in list(under) + [PAGE_BASE.get(theme)]:
                if u and u in vars_ and u != name:
                    return composite(c, solid(vars_, theme, u))
            raise ValueError("translucent %s with nothing beneath it" % name)
        return c

    # public text pairs
    for theme, fg, bg, base in PAIRS:
        for scheme in ("light", "dark"):
            vars_ = dict(default.get(theme, {}))
            vars_.update(schemed.get((theme, scheme), {}))
            try:
                fgc = resolve(vars_, fg)
                bgc = resolve(vars_, bg)
                if bgc[3] < 1.0:
                    bgc = composite(bgc, resolve(vars_, base))
            except KeyError as e:
                print("skip %-10s %-5s %s: missing %s" % (theme, scheme, fg, e))
                continue
            r = ratio(fgc, bgc)
            failures += report(r >= MIN_RATIO, theme, scheme, fg, bg, r, MIN_RATIO)

    # admin tokens: every theme, both schemes, no skipping
    for theme in THEMES:
        for scheme in ("light", "dark"):
            vars_ = dict(default.get(theme, {}))
            vars_.update(schemed.get((theme, scheme), {}))
            checks = []         # (fg, bg, floor)
            for panel in ADMIN_PANELS[theme]:
                for fg in ADMIN_TEXT:
                    checks.append((fg, panel, MIN_RATIO))
                for fg in ADMIN_UI:
                    checks.append((fg, panel, MIN_UI_RATIO))
            for fg, bg in ADMIN_FILL:
                checks.append((fg, bg, MIN_RATIO))
            for fg, bg, floor in checks:
                try:
                    fgc = solid(vars_, theme, fg, under=("--a-panel",))
                    bgc = solid(vars_, theme, bg, under=("--a-panel",))
                except (KeyError, ValueError) as e:
                    print("FAIL %-10s %-5s %-14s on %-12s missing/unresolved: %s" % (theme, scheme, fg, bg, e))
                    failures += 1
                    continue
                r = ratio(fgc, bgc)
                failures += report(r >= floor, theme, scheme, fg, bg, r, floor)

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
