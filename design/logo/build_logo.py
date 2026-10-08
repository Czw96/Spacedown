#!/usr/bin/env python3
"""Spacedown logo builder.

Writes, next to this script:  spacedown-icon.svg  (the icon the app ships)
and refreshes Spacedown/AppIcon.icns from the same geometry (needs Pillow).

    python3 build_logo.py            # ship icon + app icon
    python3 build_logo.py --all      # every colourway + lockups + sheets

What to touch:  COLORWAYS (hue), PRIMARY (which one ships), MOOD (line
treatment), MARK (centre lines), PARAMS/GAPS (wordmark).
"""
#!/usr/bin/env python3
import math

# ---------- defaults ----------
PARAMS = dict(
    sw=10.0,          # monoline stroke weight
    c_open=48.0,      # 'c' terminal angle
    e_gap=(0.0, 78.0),   # 'e' bowl opening
    a_rx=28.5,        # 'a' bowl x-radius (elliptical, keeps x-height)
    w_mid=-46.0,      # 'w' middle apex height
    w_span=86.0,      # 'w' total outer width
    S_gap=2.0, S_rx=38.0, S_alpha=45.0, S_top=-70.0,
    s_gap=3.0, s_rx=25.0, s_alpha=45.0, s_top=-70.0,
)

XH = 72.0          # x-height
CAP = 96.0         # cap height
ASC = 104.0        # ascender
DESC = 40.0        # descender

GLYPHS = {}
placed = []
WORD_ADVANCE = 0.0
WORD = "Spacedown"
GAPS = {'S': 12, 'p': 9, 'a': 12, 'c': 11, 'e': 12, 'd': 12, 'o': 12, 'w': 13, 'n': 0}


def n(v):
    return f"{round(v, 2):g}"


def polar(deg, rx, ry, cx, cy):
    a = math.radians(deg)
    return (cx + rx * math.cos(a), cy + ry * math.sin(a))


# ---------- S / s : two elliptical bowls + tangent spine ----------
def ess(H, gap, rx, alpha_deg, top_term):
    sw = PARAMS['sw']
    a = math.radians(alpha_deg)
    ry = ((H - gap) / 2.0 - sw) / 2.0

    t_u = math.pi - math.atan(ry / (rx * math.tan(a)))
    t_l = -math.atan(rx * math.tan(a) / ry)

    uy = -H + ry + sw / 2
    ly = -ry - sw / 2

    ax, ay = rx * math.cos(t_u), ry * math.sin(t_u)
    bx, by = rx * math.cos(t_l), ry * math.sin(t_l)

    dy = (ly - uy) + by - ay
    lx_ux = dy / math.tan(a) - (bx - ax)

    # place so the leftmost ink edge sits at x == 0
    if lx_ux >= 0:
        ux, lx = rx + sw / 2, rx + sw / 2 + lx_ux
    else:
        lx, ux = rx + sw / 2, rx + sw / 2 - lx_ux

    tu, tl = math.degrees(t_u), math.degrees(t_l)
    end = 180.0 + top_term            # mirrored lower terminal

    prims = [('A', ux, uy, rx, ry, top_term, tu - 360.0),
             ('L', polar(tu, rx, ry, ux, uy), polar(tl, rx, ry, lx, ly)),
             ('A', lx, ly, rx, ry, tl, end)]
    return prims, round(abs(lx_ux) + 2 * rx + sw, 2)


# ---------- the mark ----------
# Icon space is a 256x256 tile, outlined strokes.
#   primary:  "M ↓" sitting on a spacebar  -> Markdown (M) dropping down (down arrow)
#             onto the space bar (the key this app lives on)
#   alt:      "#" (markdown heading syntax) on the same spacebar
# ---------- palette ----------
# Tile colourways: a vertical gradient inside one hue (light top -> deep
# bottom). That single move is what makes an icon read as an Apple-family
# app icon; the hues follow the macOS/iOS system palette.
# name -> (top, bottom); the first entry is the one that ships.
COLORWAYS = {
    # name -> (tile top, tile bottom, mark colour, tile hairline edge or None)
    #   * tile = None  -> no tile: the mark alone, inheriting currentColor
    #     (that is the macOS "template image" case: the system tints it)
    #   * Apple's pattern is the system colour on top, a deeper cut below.
    #     Keeping the top deep enough matters: the mark is thin white monoline,
    #     so a light top washes it out (orange at #FFBB4D → 1.7:1).
    'teal':     ("#26A5BC", "#146579", "#FFFFFF", None),   # systemTeal
    'blue':     ("#1E88FF", "#0058C6", "#FFFFFF", None),   # systemBlue
    'indigo':   ("#6E6CE0", "#3C3BBA", "#FFFFFF", None),   # systemIndigo
    'purple':   ("#B266DB", "#7F33AC", "#FFFFFF", None),   # systemPurple
    'pink':     ("#F8426A", "#C41A3E", "#FFFFFF", None),   # systemPink
    'orange':   ("#F59300", "#C46C00", "#FFFFFF", None),   # systemOrange
    'green':    ("#34C759", "#1E8A41", "#FFFFFF", None),   # systemGreen
    'emerald':  ("#0A9A70", "#046349", "#FFFFFF", None),
    'graphite': ("#86898F", "#4F5257", "#FFFFFF", None),   # systemGray (dark)
    'black':    ("#4E4E52", "#2C2C30", "#FFFFFF", None),   # charcoal
    #            (bottom kept above #1B1B1D, otherwise the tile melts into a
    #             dark UI the same way a flat near-black tile does)
    'white':    ("#FFFFFF", "#E8E8EE", "#1B1B1D", "#D5D5DC"),   # paper + ink
    'mono':     (None, None, "currentColor", None),
}
PRIMARY = 'black'
ACCENT = COLORWAYS[PRIMARY][1]     # solid fallback colour
INK = "#1B1B1D"        # ink on light backgrounds
INK_DARK = "#F2F2F7"   # ink on dark backgrounds
WHITE = "#FFFFFF"

MARK_SW = 22.0      # monoline weight of the letterform / hash
ARROW_SW = 17.0     # the arrow carries the "down"; lighter so it stays airy
BAR_SW = 26.0       # the key reads as a physical object: a touch heavier
                    # (was 30 — still clearly above MARK_SW, so the hierarchy
                    #  holds, but it no longer presses down on the lockup)
TILE_R = 57.0

# ---- line treatment -------------------------------------------------------
# The same centre lines, three terminal treatments. Every element is ONE
# continuous path, so corners become real joins (a round join is a fillet of
# radius w/2) instead of two coincident round caps.
#   soft  round caps  + round joins   ... flowing, current
#   flat  flat caps   + round joins   ... crisp ends, still smooth corners
#   sharp flat caps   + miter joins   ... tightest, sharpest
MOODS = {
    'soft':  ('round', 'round'),
    'flat':  ('butt', 'round'),
    'sharp': ('butt', 'miter'),
}
MOOD = 'soft'       # shipped treatment: round ends + round corners

MARK = {
    'M': [('P', [(51, 132), (51, 68), (87, 114), (123, 68), (123, 132)])],
    'down': [('L', (185, 70), (185, 137)),
             ('P', [(163, 115), (185, 137), (207, 115)])],
    'hash': [('L', (94, 62), (94, 138)),
             ('L', (162, 62), (162, 138)),
             ('L', (84, 80), (172, 80)),
             ('L', (84, 120), (172, 120))],
    # The bar's centre-line ends are pulled OUTWARDS to compensate for the thinner
    # stroke: a round cap sticks out by sw/2, so at BAR_SW 26 the ends sit at
    # 29+13 / 227-13 instead of 44 / 212. Same outer silhouette (29..227, the
    # widest element in the mark) — only the weight changes. Without this the key
    # would also get 4 units shorter, which is not what a "make it thinner" ask
    # means.
    'spacebar': [('L', (42, 185), (214, 185))],
}
# Flat caps do not extend past the endpoint, so wherever the round version's
# silhouette came from a cap, the end must be pushed out by half the stroke.
# Per subpath, in order: (extend first end?, extend last end?).  The arrow's
# shaft must NOT grow at its bottom -- that end is buried in the head, and a
# butt cap there would poke a stub out of the tip.
EXTEND = {
    'M': (MARK_SW, [(True, True)]),
    'down': (ARROW_SW, [(True, False), (True, True)]),
}


def _push(p, q, half):
    """Return `p` moved `half` away from `q`."""
    dx, dy = p[0] - q[0], p[1] - q[1]
    L = (dx * dx + dy * dy) ** 0.5
    return (p[0] + dx / L * half, p[1] + dy / L * half)


def extend_ends(prims, half, spec):
    """Push the chosen free ends of each subpath outwards by `half`."""
    out = []
    for p, (first, last) in zip(prims, spec):
        if p[0] == 'L':
            a, b = p[1], p[2]
            out.append(('L', _push(a, b, half) if first else a,
                        _push(b, a, half) if last else b))
        elif p[0] == 'P':
            pts = list(p[1])
            if first:
                pts[0] = _push(pts[0], pts[1], half)
            if last:
                pts[-1] = _push(pts[-1], pts[-2], half)
            out.append(('P', pts))
        else:
            out.append(p)
    return out


def mark_for(mood):
    """Return {element: prims} for a treatment, plus the caps/joins to use."""
    cap, join = MOODS[mood]
    if cap == 'butt':
        prims = {}
        for k, v in MARK.items():
            if k in EXTEND:
                sw, spec = EXTEND[k]
                v = extend_ends(v, sw / 2.0, spec)
            prims[k] = v
        return prims, cap, join
    return (MARK, 'round', 'round')


def parts_for(variant='', mood=None):
    """[(id, element key, stroke weight, cap, join)] for one mark variant.

    The glyphs follow the chosen line treatment; the spacebar always keeps its
    capsule ends -- flat ends would turn the key into a plain rule and lose the
    "this is a key" reading.
    """
    mood = mood or MOOD
    cap, join = MOODS[mood]
    if variant == '-alt-hash':
        return [('hash', 'hash', MARK_SW, 'butt', 'round'),
                ('spacebar', 'spacebar', BAR_SW, 'round', 'round')]
    return [('M', 'M', MARK_SW, cap, join),
            ('down', 'down', ARROW_SW, cap, join),
            ('spacebar', 'spacebar', BAR_SW, 'round', 'round')]


MARK_VARIANTS = {'': parts_for(''), '-alt-hash': parts_for('-alt-hash')}


def prims_for(shape, variant='', mood=None):
    return mark_for(mood or MOOD)[0][shape]


# ---------- build the glyph set from PARAMS ----------
def shift(prims, dx):
    out = []
    for p in prims:
        if p[0] == 'L':
            out.append(('L', (p[1][0] + dx, p[1][1]), (p[2][0] + dx, p[2][1])))
        else:
            out.append((p[0], p[1] + dx, *p[2:]))
    return out


def normalize(prims, sw):
    """Trim the glyph to its true ink box: left edge at x=0, width == ink."""
    xs = [pt[0] for pl in to_polylines(prims) for pt in pl]
    x0, x1 = min(xs), max(xs)
    return shift(prims, sw / 2 - x0), round(x1 - x0 + sw, 2)


def build(p=None):
    global PARAMS
    if p:
        PARAMS.update(p)

    sw = PARAMS['sw']
    r = (XH - sw) / 2.0
    cy = -XH / 2.0
    ox = sw / 2 + r

    GLYPHS.clear()

    def add(ch, prims, width=None):
        if width is None:
            prims, width = normalize(prims, sw)
        GLYPHS[ch] = {'prims': prims, 'width': round(width, 2)}

    bowl = [('C', ox, cy, r, r)]

    add('o', list(bowl))

    o1 = PARAMS['c_open']
    add('c', [('A', ox, cy, r, r, -o1, -(360 - o1))])

    g1, g2 = PARAMS['e_gap']
    add('e', [('A', ox, cy, r, r, g2, g1 + 360.0),
              ('L', (ox - r, cy), (ox + r, cy))])

    arx = PARAMS['a_rx']
    acx = sw / 2 + arx
    add('a', [('L', (acx + arx, -sw / 2), (acx + arx, -XH + sw / 2)),
              ('C', acx, cy, arx, r)])

    add('d', [('L', (ox + r, -sw / 2), (ox + r, -ASC + sw / 2))] + list(bowl))

    add('p', [('L', (sw / 2, -XH + sw / 2), (sw / 2, DESC - sw / 2))] + list(bowl))

    add('n', [('L', (sw / 2, -XH + sw / 2), (sw / 2, -sw / 2)),
              ('A', ox, cy, r, r, 180, 360),
              ('L', (ox + r, cy), (ox + r, -sw / 2))])

    ww, wm = PARAMS['w_span'], PARAMS['w_mid']
    top = -XH + sw / 2
    bot = -sw / 2
    x1 = sw / 2 + (ww - sw) * 0.235
    x2 = sw / 2 + (ww - sw) * 0.5
    x3 = ww - sw / 2 - (ww - sw) * 0.235
    add('w', [('L', (sw / 2, top), (x1, bot)),
              ('L', (x1, bot), (x2, wm)),
              ('L', (x2, wm), (x3, bot)),
              ('L', (x3, bot), (ww - sw / 2, top))])

    dS, _ = ess(CAP, PARAMS['S_gap'], PARAMS['S_rx'], PARAMS['S_alpha'], PARAMS['S_top'])
    add('S', dS)
    ds, _ = ess(XH, PARAMS['s_gap'], PARAMS['s_rx'], PARAMS['s_alpha'], PARAMS['s_top'])
    add('s', ds)

    layout()


def layout():
    global placed, WORD_ADVANCE
    placed, x = [], 0.0
    for ch in WORD:
        placed.append((ch, round(x, 2)))
        x += GLYPHS[ch]['width'] + GAPS.get(ch, 12)
    WORD_ADVANCE = round(sum(GLYPHS[c]['width'] for c in WORD)
                         + sum(GAPS.get(c, 12) for c in WORD[:-1]), 2)


# ---------- emitters ----------
def to_svg_path(prims):
    out = []
    for p in prims:
        if p[0] == 'P':
            out.append("M " + " L ".join(f"{n(x)} {n(y)}" for x, y in p[1]))
        elif p[0] == 'L':
            out.append(f"M {n(p[1][0])} {n(p[1][1])} L {n(p[2][0])} {n(p[2][1])}")
        elif p[0] == 'C':
            _, cx, cy, arx, ary = p
            out.append(f"M {n(cx - arx)} {n(cy)} "
                       f"A {n(arx)} {n(ary)} 0 1 1 {n(cx + arx)} {n(cy)} "
                       f"A {n(arx)} {n(ary)} 0 1 1 {n(cx - arx)} {n(cy)}")
        else:
            _, cx, cy, arx, ary, t1, t2 = p
            s1 = polar(t1, arx, ary, cx, cy)
            s2 = polar(t2, arx, ary, cx, cy)
            span = abs(t2 - t1)
            large = 1 if span > 180 else 0
            sweep = 1 if t2 > t1 else 0
            out.append(f"M {n(s1[0])} {n(s1[1])} "
                       f"A {n(arx)} {n(ary)} 0 {large} {sweep} {n(s2[0])} {n(s2[1])}")
    return " ".join(out)


def to_polylines(prims, step=3.0):
    lines = []
    for p in prims:
        if p[0] == 'P':
            lines.append(list(p[1]))
            continue
        if p[0] == 'L':
            lines.append([p[1], p[2]])
            continue
        if p[0] == 'C':
            _, cx, cy, arx, ary = p
            t1, t2 = 0.0, 360.0
        else:
            _, cx, cy, arx, ary, t1, t2 = p
        span = t2 - t1
        circ = 2 * math.pi * max(arx, ary)
        steps = max(8, int(abs(span) / 360.0 * circ / step))
        pts = []
        for i in range(steps + 1):
            t = math.radians(t1 + span * i / steps)
            pts.append((cx + arx * math.cos(t), cy + ary * math.sin(t)))
        lines.append(pts)
    return lines


build()


def parts_with_prims(variant='', mood=None):
    """[(id, prims, stroke weight, cap, join)] — what the SVG emitter consumes."""
    prims, _, _ = mark_for(mood or MOOD)
    return [(pid, prims[shape], sw, cap, join)
            for pid, shape, sw, cap, join in parts_for(variant, mood)]



import os
import re
import sys

# By default this writes ONLY the icon the app ships (spacedown-icon.svg) and
# refreshes Spacedown/AppIcon.icns. `--all` also emits every colourway, the
# lockups and the two reference sheets.
ALL = "--all" in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))
# the built script lives in design/logo/, so the app icon is two levels up
APP_ICON_DEST = (os.environ.get("SD_APPICON")
                 or os.path.normpath(os.path.join(HERE, "..", "..", "Spacedown", "AppIcon.icns")))

OUT = os.path.dirname(os.path.abspath(__file__))
os.makedirs(OUT, exist_ok=True)

ACCENT, INK, INK_DARK, WHITE = ACCENT, INK, INK_DARK, WHITE
COLORWAYS, PRIMARY = COLORWAYS, PRIMARY

TILE = 160.0
SCALE = TILE / 256.0
GAP = 46.0
LEFT = TILE + GAP
BASE = TILE / 2.0 - (DESC - ASC) / 2.0

NOTE = {
    '': '<!-- mark: M + down arrow on the space bar -> "Markdown, dropping down" -->',
    '-alt-hash': '<!-- mark: Markdown hash on the space bar -->',
}


INSET = 0.82        # squircle / canvas — Apple's macOS icon grid


def write_appicon(cw, dest):
    """Rasterise the mark into a macOS .icns (82% inset, transparent margin).

    Needs Pillow. macOS app icons are not full-bleed: without the inset the icon
    reads larger than every other app in the Dock.
    """
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("  (Pillow not available — skipped AppIcon.icns)")
        return
    import subprocess
    import tempfile

    top, bottom, mark, _edge = cw
    parts = parts_with_prims('')
    SS = 4

    def rgb(h):
        h = h.lstrip('#')
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

    def render(size):
        T = int(round(size * INSET))
        off = (size - T) / 2.0
        w = size * SS
        img = Image.new("RGBA", (w, w), (0, 0, 0, 0))
        tw = int(round(T * SS))
        grad = Image.new("RGB", (1, tw))
        px = grad.load()
        a, b = rgb(top), rgb(bottom)
        for j in range(tw):
            f = j / max(1, tw - 1)
            px[0, j] = tuple(round(a[i] + (b[i] - a[i]) * f) for i in range(3))
        grad = grad.resize((tw, tw))
        mask = Image.new("L", (tw, tw), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, tw - 1, tw - 1], radius=TILE_R * (T / 256.0) * SS, fill=255)
        img.paste(grad, (int(round(off * SS)), int(round(off * SS))), mask)
        d = ImageDraw.Draw(img)
        k = (T / 256.0) * SS
        for _pid, prims, sw, cap, _join in parts:
            r = sw * k / 2.0
            for pl in to_polylines(prims, step=0.5):
                P = [(off * SS + x * k, off * SS + y * k) for x, y in pl]
                d.line(P, fill=mark, width=max(1, int(round(sw * k))), joint="curve")
                if cap == 'round':
                    for x, y in (P[0], P[-1]):
                        d.ellipse([x - r, y - r, x + r, y + r], fill=mark)
        return img.resize((size, size), Image.LANCZOS)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        plan = ((16, ["icon_16x16.png"]),
                (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
                (64, ["icon_32x32@2x.png"]),
                (128, ["icon_128x128.png"]),
                (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
                (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
                (1024, ["icon_512x512@2x.png"]))
        for size, names in plan:
            im = render(size)
            for nm in names:
                im.save(os.path.join(iconset, nm))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", dest], check=True)
    print("  AppIcon.icns ->", os.path.normpath(dest))


def defs(top, bottom, indent):
    i = indent
    return (f'{i}<defs>\n'
            f'{i}  <linearGradient id="tileFill" x1="0" y1="0" x2="0" y2="1">\n'
            f'{i}    <stop offset="0" stop-color="{top}"/>\n'
            f'{i}    <stop offset="1" stop-color="{bottom}"/>\n'
            f'{i}  </linearGradient>\n'
            f'{i}</defs>\n')


def mark_svg(parts, indent, scale=None, gid="icon", mark="#FFFFFF",
             tile=True, edge=None):
    """Tile (optional) + the mark. Paths are grouped by terminal style so each
    group can carry one stroke-linecap / stroke-linejoin pair; the weight sits
    on each path because it differs per element."""
    i = indent
    out = []
    if scale is not None:
        out.append(f'{i}<g id="{gid}" transform="scale({scale:.4f})">')
        i += "  "
    if tile:
        out.append(f'{i}<rect id="tile" width="256" height="256"'
                   f' rx="{n(TILE_R)}" fill="url(#tileFill)"/>')
        if edge:
            out.append(f'{i}<rect id="edge" x="1" y="1" width="254" height="254"'
                       f' rx="{n(TILE_R)}" fill="none" stroke="{edge}"'
                       f' stroke-width="2"/>')
    runs = []
    for pid, prims, sw, cap, join in parts:
        key = (cap, join)
        if key not in [r[0] for r in runs]:
            runs.append((key, []))
        runs[[r[0] for r in runs].index(key)][1].append((pid, prims, sw))
    used = set()
    for (cap, join), items in runs:
        rid = "key" if all(pid == "spacebar" for pid, _, _ in items) else "mark"
        while rid in used:
            rid += "2"
        used.add(rid)
        out.append(f'{i}<g id="{rid}" fill="none" stroke="{mark}"'
                   f' stroke-linecap="{cap}" stroke-linejoin="{join}">')
        for pid, prims, sw in items:
            out.append(f'{i}  <path id="{pid}" stroke-width="{n(sw)}"'
                       f' d="{to_svg_path(prims)}"/>')
        out.append(f'{i}</g>')
    if scale is not None:
        out.append(f'{indent}</g>')
    return "\n".join(out) + "\n"


def icon_file(parts, cw, variant=""):
    top, bottom, mark, edge = cw
    head = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" '
            'width="256" height="256" role="img" aria-label="Spacedown">\n'
            '  <title>Spacedown</title>\n'
            f'  {NOTE[variant]}\n')
    body = ""
    if top is not None:
        body += defs(top, bottom, "  ")
    else:
        # no tile: let the mark follow the surrounding text colour
        body += (f'  <style>\n    svg {{ color: {INK}; }}\n'
                 f'    @media (prefers-color-scheme: dark) {{ svg {{ color: {INK_DARK}; }} }}\n'
                 f'  </style>\n')
    body += mark_svg(parts, "  ", mark=mark, tile=top is not None, edge=edge)
    return head + body + '</svg>\n'


def lockup_file(parts, cw, variant=""):
    top, bottom, mark, edge = cw
    W = round(LEFT + WORD_ADVANCE, 2)
    glyphs = "\n".join(
        (f'    <path id="{ch}" transform="translate({n(x)} 0)"' if x else
         f'    <path id="{ch}"') +
        f'\n          d="{to_svg_path(GLYPHS[ch]["prims"])}"/>'
        for ch, x in placed
    )
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n(W)} {n(TILE)}" width="{n(W)}" height="{n(TILE)}" role="img" aria-label="Spacedown">
  <title>Spacedown</title>
  <style>
    svg {{ color: {INK}; }}
    @media (prefers-color-scheme: dark) {{ svg {{ color: {INK_DARK}; }} }}
  </style>
{defs(top, bottom, "  ")}
  {NOTE[variant]}
{mark_svg(parts, "  ", SCALE, mark=mark, edge=edge)}
  <!-- wordmark: "Spacedown", drawn as outlines (no font dependency) -->
  <g id="wordmark" transform="translate({n(LEFT)} {n(BASE)})" fill="none"
     stroke="currentColor" stroke-width="{n(PARAMS['sw'])}"
     stroke-linecap="round" stroke-linejoin="round">
{glyphs}
  </g>
</svg>
'''
    return svg, W


primary_parts = parts_with_prims('')
alt_parts = parts_with_prims('-alt-hash')

files = {}
if ALL:
    for name, cw in COLORWAYS.items():
        svg = icon_file(primary_parts, cw)
        files[name] = svg
        fn = "spacedown-icon.svg" if name == PRIMARY else f"spacedown-icon-{name}.svg"
        open(os.path.join(OUT, fn), "w").write(svg)
    open(os.path.join(OUT, "spacedown-icon-alt-hash.svg"), "w").write(
        icon_file(alt_parts, COLORWAYS[PRIMARY], "-alt-hash"))
    horiz, W = lockup_file(primary_parts, COLORWAYS[PRIMARY])
    open(os.path.join(OUT, "spacedown-logo-horizontal.svg"), "w").write(horiz)
    horiz_alt, _ = lockup_file(alt_parts, COLORWAYS[PRIMARY], "-alt-hash")
    open(os.path.join(OUT, "spacedown-logo-horizontal-alt-hash.svg"), "w").write(horiz_alt)
else:
    files[PRIMARY] = icon_file(primary_parts, COLORWAYS[PRIMARY])
    open(os.path.join(OUT, "spacedown-icon.svg"), "w").write(files[PRIMARY])
    write_appicon(COLORWAYS[PRIMARY], APP_ICON_DEST)
    print("shipped icon:", PRIMARY, COLORWAYS[PRIMARY])
    print("files:", sorted(os.listdir(OUT)))
    sys.exit(0)


# ---------------- colourways sheet ----------------
_uid = [0]


def sized(svg, w, h):
    """Pin both dimensions and namespace every id, so the same artwork can be
    inlined many times on one sheet without clashing (the gradient url must
    keep pointing at its own definition)."""
    _uid[0] += 1
    ns = _uid[0]
    svg = re.sub(r'\bid="([^"]*)"', lambda m: f'id="{m.group(1)}-{ns}"', svg)
    svg = re.sub(r'url\(#([^)]*)\)', lambda m: f'url(#{m.group(1)}-{ns})', svg)
    return svg.replace("<svg ", f'<svg style="width:{w}px;height:{h}px" ', 1)


def cell(name, h, on_dark=False):
    t, b, mark, edge = COLORWAYS[name]
    tag = " ← current" if name == PRIMARY else ""
    tone = " · ink" if mark != "#FFFFFF" else ""
    spec = "no tile · currentColor" if t is None else f"{t} → {b}{tone}"
    return (f'<figure>{sized(files[name], h, h)}'
            f'<figcaption>{name}{tag}<br>{spec}</figcaption></figure>')


MOOD_NOTE = {
    'soft': 'round ends + round corners',
    'flat': 'flat ends + round corners &nbsp;←&nbsp; shipping',
    'sharp': 'flat ends + mitred corners',
}


def mood_row():
    cells = []
    for mood in MOODS:
        svg = icon_file(parts_with_prims('', mood), COLORWAYS[PRIMARY])
        cells.append('<figure>' + sized(svg, 150, 150)
                     + f'<figcaption>{mood}<br>{MOOD_NOTE[mood]}</figcaption></figure>')
    return ('\n<h2>line treatment · same centre lines, three terminal styles</h2>\n'
            '<div class="grid">' + "".join(cells) + '</div>\n')


ladder = "\n".join(f'<figure>{sized(files[PRIMARY], s, s)}'
                   f'<figcaption>{s}px</figcaption></figure>' for s in (256, 128, 64, 32, 16))

colors_html = f'''<!doctype html>
<meta charset="utf-8">
<title>Spacedown icon · colourways</title>
<style>
  body {{ margin:0; font:13px/1.5 -apple-system,system-ui,sans-serif; color:{INK}; }}
  h2 {{ font:600 11px/1 ui-monospace,SFMono-Regular,monospace; letter-spacing:.14em;
        text-transform:uppercase; opacity:.45; margin:30px 32px 0; }}
  .grid {{ display:flex; flex-wrap:wrap; gap:30px; padding:18px 32px 10px; }}
  .dark {{ background:{INK}; color:{INK_DARK}; padding:1px 0 26px; margin-top:26px; }}
  .dark h2, .dark figcaption {{ color:{INK_DARK}; }}
  figure {{ margin:0; }}
  figcaption {{ padding-top:10px; font:10px/1.45 ui-monospace,SFMono-Regular,monospace;
                opacity:.55; }}
</style>

<h2>light background · 128px</h2>
<div class="grid">{"".join(cell(n, 128) for n in COLORWAYS)}</div>

<div class="dark">
  <h2>dark background · 64px</h2>
  <div class="grid">{"".join(cell(n, 64) for n in COLORWAYS)}</div>
</div>

<h2>size ladder · {PRIMARY}</h2>
<div class="grid">{ladder}</div>
{mood_row()}
'''
open(os.path.join(OUT, "colors.html"), "w").write(colors_html)

# ---------------- preview.html ----------------
strip = lambda svgs: f'<span class="strip">{"".join(svgs)}</span>'
preview = f'''<!doctype html>
<meta charset="utf-8">
<title>Spacedown logo</title>
<style>
  body {{ margin:0; font:13px/1.5 -apple-system,system-ui,sans-serif; }}
  .row {{ padding:26px 32px; }}
  .light {{ background:#fff; }}
  .dark {{ background:{INK}; }}
  .dark svg {{ color:{INK_DARK}; }}
  .lbl {{ font:600 11px/1 ui-monospace,SFMono-Regular,monospace; letter-spacing:.14em;
          text-transform:uppercase; opacity:.45; display:block; padding-bottom:16px; }}
  .light .lbl {{ color:{INK}; }}
  .dark .lbl {{ color:{INK_DARK}; }}
  .strip {{ display:flex; align-items:center; gap:26px; }}
</style>
<div class="row light"><span class="lbl">icon · light · {PRIMARY}</span>
{strip(sized(files[PRIMARY], s, s) for s in (200, 96, 48, 32, 16))}</div>
<div class="row dark"><span class="lbl">icon · dark</span>
{strip(sized(files[PRIMARY], s, s) for s in (200, 96, 48, 32, 16))}</div>
<div class="row light"><span class="lbl">lockup · light</span>
{strip(sized(horiz, round(h * W / TILE), h) for h in (160, 96, 51))}</div>
<div class="row dark"><span class="lbl">lockup · dark</span>
{strip(sized(horiz, round(h * W / TILE), h) for h in (160, 96))}</div>
<div class="row light"><span class="lbl">wordmark · 1.6x</span>
{strip([sized(horiz, round(256 * W / TILE), 256)])}</div>
'''
open(os.path.join(OUT, "preview.html"), "w").write(preview)

print("primary:", PRIMARY, COLORWAYS[PRIMARY])
print("files:", sorted(os.listdir(OUT)))
