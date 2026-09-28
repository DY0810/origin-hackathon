#!/usr/bin/env python3
"""WCAG 2.1 contrast check for every Mend token pair that carries meaning.
Run: python3 design-system/contrast_check.py   (exits 1 on any failure)
Keep TOKENS in sync with DesignSystem.swift. If you change a hex there, change it here and re-run."""

TOKENS = {
    #            light       dark
    "canvas":   ("#FFFFFF", "#0F141C"),
    "surface":  ("#FEFEFE", "#18212D"),
    "surface2": ("#F0F7FD", "#222D3B"),
    "ink":      ("#18212D", "#F4F6FA"),   # Midnight
    "ink2":     ("#4E6A86", "#A9BACD"),   # deep slate (raw Slate #6887A4 is only 3.76:1 on canvas)
    "ink3":     ("#6887A4", "#8A9FB6"),   # Slate: large or non-essential only
    "stroke":   ("#6887A4", "#6887A4"),   # control boundaries (3:1 non-text)
    "brand":    ("#18212D", "#ADD9F3"),   # primary button fill
    "onBrand":  ("#FEFEFE", "#18212D"),
    "accent":   ("#ADD9F3", "#2B4A66"),   # Sky: chips, hero cards, secondary buttons
    "onAccent": ("#18212D", "#F4F6FA"),
    "accentText": ("#2F6690", "#ADD9F3"), # sky-blue used AS text (links)
    "gold":     ("#FFE66D", "#FFE66D"),   # Sunbeam: points / value / bounty heat
    "onGold":   ("#18212D", "#18212D"),
    "goldText": ("#7A5E00", "#FFE66D"),   # gold used AS text on canvas/surface
    "success":  ("#1B7F4B", "#4CC38A"),
    "warning":  ("#A15C00", "#F5B040"),
    "danger":   ("#C8202F", "#FF6B6B"),
    "sev1":     ("#5B6878", "#9AA6B6"),   # cosmetic
    "sev2":     ("#1F72C4", "#5AA9F0"),   # monitor
    "sev3":     ("#9E6300", "#F0A62A"),   # schedule repair
    "sev4":     ("#C9480A", "#FF8540"),   # urgent
    "sev5":     ("#C8202F", "#FF5A64"),   # hazard
    "onSev":    ("#FFFFFF", "#0F141C"),   # numeral/icon inside a filled severity badge
}

# (foreground, background, minimum ratio, why)
PAIRS = [
    ("ink", "canvas", 4.5, "body text"),
    ("ink", "surface", 4.5, "body text on cards"),
    ("ink", "surface2", 4.5, "body text on inset"),
    ("ink2", "canvas", 4.5, "secondary text"),
    ("ink2", "surface", 4.5, "secondary text on cards"),
    ("ink3", "surface", 3.0, "tertiary: large/non-essential only"),
    ("stroke", "surface", 3.0, "control boundary (1.4.11)"),
    ("brand", "surface", 4.5, "brand fill / text on cards"),
    ("brand", "canvas", 4.5, "brand fill / text on canvas"),
    ("onBrand", "brand", 4.5, "primary button label"),
    ("onAccent", "accent", 4.5, "secondary button / selected chip label"),
    ("ink2", "surface2", 4.5, "secondary text on chips / insets"),
    ("accentText", "surface", 4.5, "link text on cards"),
    ("accentText", "canvas", 4.5, "link text on canvas"),
    ("onGold", "gold", 4.5, "points pill label"),
    ("goldText", "surface", 4.5, "gold-colored text"),
    ("success", "surface", 4.5, "success text"),
    ("warning", "surface", 4.5, "warning text"),
    ("danger", "surface", 4.5, "error text"),
] + [(f"sev{i}", "surface", 3.0, f"severity {i} glyph/badge fill vs card (1.4.11)") for i in range(1, 6)] \
  + [("onSev", f"sev{i}", 4.5, f"numeral on severity {i} badge") for i in range(1, 6)]


def lum(hex_):
    c = [int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


if __name__ == "__main__":
    assert round(ratio("#000000", "#FFFFFF"), 1) == 21.0
    fails = 0
    print(f"{'pair':<22}{'mode':<6}{'ratio':>7}{'min':>5}  use")
    for fg, bg, need, why in PAIRS:
        for mode, idx in (("light", 0), ("dark", 1)):
            r = ratio(TOKENS[fg][idx], TOKENS[bg][idx])
            ok = r >= need
            fails += not ok
            print(f"{fg + '/' + bg:<22}{mode:<6}{r:7.2f}{need:5.1f}  {'OK ' if ok else 'FAIL'} {why}")
    print(f"\n{fails} failure(s)")
    raise SystemExit(1 if fails else 0)
