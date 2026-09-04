#!/usr/bin/env python3
"""Line-art icons for notebook cover pages.

Each icon is a small function that draws into a unit box with an `IconPen`:
coordinates run 0..1 left-to-right and top-to-bottom, matching page space, so
an icon can be dropped anywhere at any size. Nothing here knows whether it is
ending up in a PDF or in reMarkable's template DSL — it all goes through the
Canvas.shape() primitive.

Why procedural rather than a table of SVG path data: at this scale the shapes
are circles, rounded rectangles and arcs, and a dozen readable lines of Python
beat a 400-character `d` attribute nobody can edit. Add an icon by writing a
function and decorating it with @icon("name").
"""

from __future__ import annotations

import math

# Grey levels, matched to the rest of the skill. The panel is 16-level
# greyscale; a fill much darker than this competes with your ink.
INK_LINE = (0.10, 0.10, 0.10)
INK_FILL = (0.80, 0.80, 0.80)

REGISTRY = {}


def icon(name):
    def wrap(fn):
        REGISTRY[name] = fn
        return fn
    return wrap


def rrect_pts(x0, y0, x1, y1, r):
    """A rounded rectangle as a point list. Unit or page coordinates alike."""
    r = min(r, abs(x1 - x0) / 2, abs(y1 - y0) / 2)
    if r <= 0:
        return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    k, pts = 6, []
    # top-left, top-right, bottom-right, bottom-left, walking clockwise
    for cx, cy, a0 in ((x0 + r, y0 + r, 180), (x1 - r, y0 + r, 90),
                       (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 270)):
        for i in range(k + 1):
            a = math.radians(a0 - 90 * i / k)
            pts.append((cx + r * math.cos(a), cy - r * math.sin(a)))
    return pts


def lobes(circles, start_a, end_a):
    """Trace over the top of a chain of overlapping circles, as one outline.

    Eyeballing where one lobe should hand over to the next does not work — the
    straight hop between two guessed angles cuts a visible notch or a spike out
    of the silhouette. So each hand-over point is the actual upper intersection
    of the two circles, solved for rather than guessed.

    `circles` is [(cx, cy, r), ...] left to right; the outline runs from
    `start_a` on the first to `end_a` on the last, both in the arc_pts
    convention (degrees, 90 is up), sweeping clockwise on screen.
    """
    pts, a_in = [], start_a
    for i, (cx, cy, r) in enumerate(circles):
        if i + 1 < len(circles):
            nx, ny, nr = circles[i + 1]
            dx, dy = nx - cx, ny - cy
            d = math.hypot(dx, dy)
            a = (d * d + r * r - nr * nr) / (2 * d)
            h = math.sqrt(max(r * r - a * a, 0.0))
            px, py = cx + a * dx / d, cy + a * dy / d
            ix, iy = px + h * dy / d, py - h * dx / d      # the upper crossing
            a_out = math.degrees(math.atan2(-(iy - cy), ix - cx))
            a_next = math.degrees(math.atan2(-(iy - ny), ix - nx))
        else:
            a_out = a_next = end_a
        while a_out > a_in:
            a_out -= 360
        n = max(4, int((a_in - a_out) / 8) + 2)
        pts += [(cx + r * math.cos(math.radians(a_in + (a_out - a_in) * k / n)),
                 cy - r * math.sin(math.radians(a_in + (a_out - a_in) * k / n)))
                for k in range(n + 1)]
        a_in = a_next
    return pts


class IconPen:
    """Draws unit-box shapes onto a Canvas at a given position and size.

    `lw` is the base stroke width in points, derived from the icon size so the
    outlines stay proportionally heavy whether the icon is 30 pt or 130 pt.
    """

    def __init__(self, cv, x, y, size, weight=0.030):
        self.cv, self.x, self.y, self.s = cv, x, y, size
        self.lw = max(0.5, size * weight)

    def P(self, u, v):
        return (self.x + u * self.s, self.y + v * self.s)

    def _w(self, w):
        return self.lw if w is None else self.lw * w

    def poly(self, pts, fill=None, close=False, w=None, stroke=INK_LINE):
        self.cv.shape([[self.P(*p) for p in pts]], ink=stroke, width=self._w(w),
                      fill=fill, close=close)

    def line(self, x0, y0, x1, y1, w=None):
        self.poly([(x0, y0), (x1, y1)], w=w)

    def arc_pts(self, cx, cy, rx, ry, a0, a1, steps=None):
        """Points along an ellipse. Angles in degrees, counter-clockwise with 0
        at 3 o'clock — so a positive angle goes *up* even though v grows down."""
        n = steps or max(4, int(abs(a1 - a0) / 8) + 2)
        return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
                 cy - ry * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
                for i in range(n + 1)]

    def arc(self, cx, cy, r, a0, a1, w=None, ry=None):
        self.poly(self.arc_pts(cx, cy, r, r if ry is None else ry, a0, a1), w=w)

    def circle(self, cx, cy, r, fill=None, w=None, ry=None):
        self.poly(self.arc_pts(cx, cy, r, r if ry is None else ry, 0, 360, 44),
                  fill=fill, close=True, w=w)

    def dot(self, cx, cy, r):
        self.circle(cx, cy, r, fill=INK_LINE, w=0.3)

    def rrect(self, x0, y0, x1, y1, r=0.0, fill=None, w=None):
        self.poly(rrect_pts(x0, y0, x1, y1, r), fill=fill, close=True, w=w)


# --- the library -------------------------------------------------------------

@icon("person")
def _person(p):
    """A figure at a desk. The stock centrepiece for a team notebook."""
    p.circle(0.50, 0.36, 0.158, ry=0.182, w=1.0)                      # head
    # The fringe goes on after the head so it covers the top of that outline,
    # and its chord has to sit above the glasses or it eats them.
    p.poly(p.arc_pts(0.50, 0.36, 0.162, 0.188, 165, 15),
           fill=INK_FILL, close=True, w=0.7)
    p.circle(0.442, 0.392, 0.054, ry=0.046, w=0.45)                   # glasses
    p.circle(0.558, 0.392, 0.054, ry=0.046, w=0.45)
    p.poly(p.arc_pts(0.50, 0.455, 0.062, 0.042, 205, 335), w=0.7)     # smile
    p.poly([(0.44, 0.530), (0.50, 0.585), (0.56, 0.530)], w=0.9)      # collar
    p.poly([(0.50, 0.585), (0.462, 0.645), (0.50, 0.845), (0.538, 0.645)],
           fill=INK_FILL, close=True, w=0.8)                          # tie
    # Shoulders drop away to the edges of the box rather than meeting below —
    # a narrow V reads as a stick figure at thumbnail size.
    p.poly([(0.15, 0.98), (0.20, 0.80), (0.31, 0.63), (0.44, 0.530)], w=1.0)
    p.poly([(0.85, 0.98), (0.80, 0.80), (0.69, 0.63), (0.56, 0.530)], w=1.0)


@icon("code-window")
def _code_window(p):
    p.rrect(0.04, 0.10, 0.96, 0.90, 0.10, w=1.0)
    p.line(0.04, 0.32, 0.96, 0.32, 0.8)
    for cx in (0.15, 0.26, 0.37):
        p.dot(cx, 0.21, 0.033)
    p.poly([(0.40, 0.44), (0.26, 0.61), (0.40, 0.78)], w=1.0)
    p.poly([(0.60, 0.44), (0.74, 0.61), (0.60, 0.78)], w=1.0)
    p.line(0.545, 0.42, 0.455, 0.80, 0.8)


@icon("gear")
def _gear(p):
    pts, n = [], 8
    for i in range(n):
        a0 = 360 * i / n
        pts += p.arc_pts(0.5, 0.5, 0.47, 0.47, a0 - 13, a0 + 13, 3)
        pts += p.arc_pts(0.5, 0.5, 0.345, 0.345, a0 + 16, a0 + 360 / n - 16, 3)
    p.poly(pts, fill=INK_FILL, close=True, w=1.0)
    p.circle(0.5, 0.5, 0.155, w=1.0)


@icon("lightbulb")
def _lightbulb(p):
    # 90 degrees is the *top* here, so the glass sweeps 210 down to -30 the
    # short way over the crown; going 210 to 330 draws the bottom instead.
    p.poly(p.arc_pts(0.50, 0.38, 0.30, 0.32, 210, -30) + [(0.63, 0.68), (0.37, 0.68)],
           close=True, w=1.0)
    p.rrect(0.37, 0.68, 0.63, 0.79, 0.02, fill=INK_FILL, w=0.8)
    p.line(0.37, 0.735, 0.63, 0.735, 0.6)
    p.rrect(0.415, 0.79, 0.585, 0.88, 0.03, w=0.8)
    p.poly([(0.42, 0.62), (0.44, 0.40), (0.50, 0.34), (0.56, 0.40), (0.58, 0.62)], w=0.8)


@icon("bar-chart")
def _bar_chart(p):
    p.line(0.04, 0.94, 0.98, 0.94, 1.0)
    for i, (h, fill) in enumerate(((0.24, None), (0.44, INK_FILL),
                                   (0.66, None), (0.90, INK_FILL))):
        x = 0.09 + i * 0.22
        p.rrect(x, 0.94 - h, x + 0.17, 0.94, 0.0, fill=fill, w=0.9)


@icon("laptop")
def _laptop(p):
    p.poly([(0.20, 0.22), (0.95, 0.22), (0.95, 0.70), (0.20, 0.70)],
           fill=INK_FILL, close=True, w=1.0)
    p.poly([(0.05, 0.86), (0.28, 0.70), (0.99, 0.70), (0.99, 0.86)], close=True, w=1.0)
    p.line(0.02, 0.94, 0.99, 0.94, 1.0)


@icon("arrow-up")
def _arrow_up(p):
    p.poly(p.arc_pts(0.06, 0.06, 0.82, 0.84, 288, 349), w=1.2)
    p.poly([(0.99, 0.14), (0.63, 0.27), (0.84, 0.53)], fill=INK_FILL, close=True, w=1.0)


@icon("cloud")
def _cloud(p):
    p.poly(lobes([(0.28, 0.62, 0.20), (0.54, 0.46, 0.26), (0.78, 0.64, 0.18)],
                 215, -35), fill=INK_FILL, close=True, w=1.0)


@icon("database")
def _database(p):
    p.circle(0.5, 0.24, 0.40, ry=0.14, fill=INK_FILL, w=1.0)
    for y in (0.24, 0.50):
        p.line(0.10, y, 0.10, y + 0.26, 1.0)
        p.line(0.90, y, 0.90, y + 0.26, 1.0)
        p.poly(p.arc_pts(0.5, y + 0.26, 0.40, 0.14, 180, 360), w=1.0)


@icon("calendar")
def _calendar(p):
    p.rrect(0.06, 0.14, 0.94, 0.94, 0.08, w=1.0)
    p.poly([(0.06, 0.36), (0.94, 0.36)] +
           p.arc_pts(0.86, 0.22, 0.08, 0.08, 0, 90) +
           p.arc_pts(0.14, 0.22, 0.08, 0.08, 90, 180),
           fill=INK_FILL, close=True, w=1.0)
    p.line(0.28, 0.06, 0.28, 0.24, 1.2)
    p.line(0.72, 0.06, 0.72, 0.24, 1.2)
    for r in range(2):
        for c in range(3):
            p.dot(0.25 + c * 0.25, 0.54 + r * 0.22, 0.045)


@icon("checklist")
def _checklist(p):
    p.rrect(0.10, 0.10, 0.90, 0.96, 0.08, w=1.0)
    p.rrect(0.34, 0.02, 0.66, 0.18, 0.04, fill=INK_FILL, w=0.8)
    for i in range(3):
        y = 0.38 + i * 0.20
        p.rrect(0.20, y - 0.07, 0.34, y + 0.07, 0.02, w=0.8)
        p.line(0.42, y, 0.80, y, 0.8)
    p.poly([(0.225, 0.38), (0.27, 0.43), (0.335, 0.31)], w=1.1)


@icon("chat")
def _chat(p):
    # rrect_pts walks clockwise in four 7-point corners, so the tail belongs
    # spliced into the bottom edge after the bottom-right corner. Appended at
    # the end instead, it draws a line back across the bubble.
    box = rrect_pts(0.04, 0.10, 0.96, 0.70, 0.14)
    p.poly(box[:21] + [(0.46, 0.70), (0.30, 0.98), (0.28, 0.70)] + box[21:],
           fill=INK_FILL, close=True, w=1.0)
    for i in range(3):
        p.dot(0.30 + i * 0.20, 0.40, 0.05)


@icon("target")
def _target(p):
    p.circle(0.5, 0.5, 0.46, w=1.0)
    p.circle(0.5, 0.5, 0.29, fill=INK_FILL, w=0.9)
    p.circle(0.5, 0.5, 0.11, fill=INK_LINE, w=0.9)


@icon("book")
def _book(p):
    p.poly([(0.50, 0.24), (0.10, 0.14), (0.04, 0.18), (0.04, 0.84),
            (0.10, 0.80), (0.50, 0.90)], fill=INK_FILL, close=True, w=1.0)
    p.poly([(0.50, 0.24), (0.90, 0.14), (0.96, 0.18), (0.96, 0.84),
            (0.90, 0.80), (0.50, 0.90)], close=True, w=1.0)
    p.line(0.50, 0.24, 0.50, 0.90, 1.0)


@icon("flask")
def _flask(p):
    p.poly([(0.36, 0.06), (0.36, 0.38), (0.12, 0.86), (0.88, 0.86),
            (0.64, 0.38), (0.64, 0.06)], close=True, w=1.0)
    p.poly([(0.275, 0.56), (0.16, 0.79), (0.84, 0.79), (0.725, 0.56)],
           fill=INK_FILL, close=True, w=0.7)
    p.line(0.30, 0.06, 0.70, 0.06, 1.2)
    p.dot(0.42, 0.68, 0.04)
    p.dot(0.60, 0.72, 0.03)


@icon("lock")
def _lock(p):
    p.poly(p.arc_pts(0.50, 0.44, 0.26, 0.30, 0, 180), w=1.2)
    p.rrect(0.12, 0.44, 0.88, 0.94, 0.08, fill=INK_FILL, w=1.0)
    p.circle(0.50, 0.64, 0.08, fill=INK_LINE, w=0.7)
    p.line(0.50, 0.68, 0.50, 0.80, 1.2)


@icon("network")
def _network(p):
    nodes = ((0.50, 0.10), (0.10, 0.55), (0.90, 0.55), (0.30, 0.94), (0.70, 0.94))
    for a, b in ((0, 1), (0, 2), (1, 3), (2, 4), (3, 4), (1, 2)):
        p.line(nodes[a][0], nodes[a][1], nodes[b][0], nodes[b][1], 0.7)
    for i, (cx, cy) in enumerate(nodes):
        p.circle(cx, cy, 0.115, fill=INK_LINE if i == 0 else INK_FILL, w=0.9)


@icon("clock")
def _clock(p):
    p.circle(0.5, 0.5, 0.46, w=1.1)
    p.circle(0.5, 0.5, 0.37, fill=INK_FILL, w=0.5)
    p.line(0.5, 0.5, 0.5, 0.22, 1.2)
    p.line(0.5, 0.5, 0.72, 0.60, 1.2)


@icon("folder")
def _folder(p):
    p.poly([(0.04, 0.88), (0.04, 0.18), (0.38, 0.18), (0.46, 0.32),
            (0.96, 0.32), (0.96, 0.88)], fill=INK_FILL, close=True, w=1.0)
    p.line(0.04, 0.44, 0.96, 0.44, 0.8)


@icon("rocket")
def _rocket(p):
    p.poly([(0.50, 0.03), (0.62, 0.22), (0.66, 0.45), (0.66, 0.72),
            (0.34, 0.72), (0.34, 0.45), (0.38, 0.22)], close=True, w=1.1)
    p.poly([(0.34, 0.46), (0.13, 0.76), (0.34, 0.72)], fill=INK_FILL, close=True, w=0.9)
    p.poly([(0.66, 0.46), (0.87, 0.76), (0.66, 0.72)], fill=INK_FILL, close=True, w=0.9)
    p.circle(0.50, 0.34, 0.105, fill=INK_FILL, w=0.8)
    p.poly([(0.42, 0.72), (0.50, 0.97), (0.58, 0.72)], close=True, w=0.9)


@icon("shield")
def _shield(p):
    p.poly([(0.06, 0.20), (0.50, 0.04), (0.94, 0.20), (0.94, 0.52)] +
           p.arc_pts(0.50, 0.52, 0.44, 0.44, 0, -180) + [(0.06, 0.52)],
           fill=INK_FILL, close=True, w=1.1)
    p.poly([(0.30, 0.46), (0.44, 0.62), (0.72, 0.30)], w=1.3)


@icon("magnifier")
def _magnifier(p):
    p.circle(0.40, 0.40, 0.36, w=1.2)
    p.circle(0.40, 0.40, 0.26, fill=INK_FILL, w=0.5)
    p.line(0.66, 0.66, 0.95, 0.95, 1.7)


@icon("ship")
def _ship(p):
    p.poly([(0.02, 0.66), (0.98, 0.66), (0.82, 0.94), (0.18, 0.94)], close=True, w=1.1)
    for i in range(3):
        x = 0.20 + i * 0.21
        p.rrect(x, 0.42, x + 0.19, 0.64, 0.0, fill=INK_FILL if i % 2 else None, w=0.8)
    p.rrect(0.20, 0.20, 0.39, 0.40, 0.0, w=0.8)
    p.line(0.05, 0.73, 0.95, 0.73, 0.6)


@icon("puzzle")
def _puzzle(p):
    # The body is inset top and right so the two tabs have somewhere to bulge
    # into without leaving the unit box.
    p.poly([(0.06, 0.16), (0.36, 0.16)] + p.arc_pts(0.46, 0.16, 0.10, 0.10, 180, 0) +
           [(0.86, 0.16), (0.86, 0.45)] +
           p.arc_pts(0.86, 0.55, 0.10, 0.10, 90, -90) +
           [(0.86, 0.94), (0.06, 0.94)],
           fill=INK_FILL, close=True, w=1.1)


@icon("key")
def _key(p):
    p.circle(0.28, 0.30, 0.24, w=1.1)
    p.circle(0.28, 0.30, 0.10, fill=INK_LINE, w=0.6)
    p.line(0.44, 0.46, 0.94, 0.96, 1.4)
    p.line(0.70, 0.72, 0.58, 0.84, 1.2)
    p.line(0.82, 0.84, 0.70, 0.96, 1.2)


@icon("monitor")
def _monitor(p):
    p.rrect(0.04, 0.10, 0.96, 0.68, 0.06, fill=INK_FILL, w=1.1)
    p.line(0.50, 0.68, 0.50, 0.84, 1.1)
    p.line(0.26, 0.90, 0.74, 0.90, 1.5)


@icon("graph-line")
def _graph_line(p):
    p.line(0.08, 0.06, 0.08, 0.90, 1.0)
    p.line(0.08, 0.90, 0.96, 0.90, 1.0)
    pts = [(0.20, 0.72), (0.40, 0.46), (0.60, 0.60), (0.86, 0.20)]
    p.poly(pts, w=1.2)
    for cx, cy in pts:
        p.circle(cx, cy, 0.055, fill=INK_FILL, w=0.7)


@icon("bug")
def _bug(p):
    p.circle(0.50, 0.58, 0.30, ry=0.34, fill=INK_FILL, w=1.1)
    p.line(0.50, 0.26, 0.50, 0.92, 0.7)
    p.circle(0.50, 0.22, 0.16, ry=0.13, w=1.0)
    p.line(0.42, 0.11, 0.34, 0.02, 0.9)
    p.line(0.58, 0.11, 0.66, 0.02, 0.9)
    for y in (0.44, 0.60, 0.76):
        p.line(0.22, y, 0.04, y - 0.07, 0.9)
        p.line(0.78, y, 0.96, y - 0.07, 0.9)


@icon("pen")
def _pen(p):
    p.poly([(0.72, 0.04), (0.96, 0.28), (0.34, 0.90), (0.06, 0.96), (0.12, 0.68)],
           fill=INK_FILL, close=True, w=1.1)
    p.line(0.12, 0.68, 0.34, 0.90, 0.8)
    p.line(0.60, 0.16, 0.84, 0.40, 0.8)


@icon("stack")
def _stack(p):
    for i, y in enumerate((0.66, 0.44, 0.22)):
        p.poly([(0.50, y - 0.17), (0.96, y), (0.50, y + 0.17), (0.04, y)],
               fill=INK_FILL if i == 2 else None, close=True, w=1.0)


@icon("globe")
def _globe(p):
    p.circle(0.5, 0.5, 0.46, w=1.1)
    p.line(0.04, 0.50, 0.96, 0.50, 0.7)
    p.poly(p.arc_pts(0.5, 0.5, 0.46, 0.21, 90, -90), w=0.7)
    p.poly(p.arc_pts(0.5, 0.5, 0.46, 0.21, 90, 270), w=0.7)
    p.poly(p.arc_pts(0.5, 0.5, 0.21, 0.46, 0, 180), w=0.7)
    p.poly(p.arc_pts(0.5, 0.5, 0.21, 0.46, 180, 360), w=0.7)


def draw(cv, name, x, y, size, weight=0.030):
    fn = REGISTRY.get(name)
    if fn is None:
        raise KeyError(name)
    fn(IconPen(cv, x, y, size, weight))


def names():
    return sorted(REGISTRY)
