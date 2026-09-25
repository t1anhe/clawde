#!/usr/bin/env python3
"""Clawd's own actions, drawn the way the Code tab's Clawd and the Fable 5
film draw it.

Each action is frame-by-frame pixel art written out as a Lottie file shaped
like Clawd-Laptop: one shape layer per colour, one group of rectangles per
frame, each group's fill switched on only on its own frame by hold keyframes.
Any Lottie player can play them, and tools/import_clawd.py turns them into
the pet's blocks.

The style is Anthropic's own, from the Code tab's Clawd, the Fable 5 film
and the Claude FM stream. Everything solid is drawn in Clawd's own pixels,
half a grid unit square, as the film's letters are: eyes, props and all,
in flat colours. A prop takes its own natural colour in two or three tones,
a darker one for its edges and underside and sometimes a lighter one, as
Claude FM draws Clawd's backpack; a dark prop keeps a lighter tone so it
still reads on a dark desktop. What is dim or glowing is drawn in the
film's finer dots, a quarter unit square in the middle of a cell, and light
is a halftone of cream dots, thickest by the light, never a highlight.
Clawd acts with its whole body: squashing, stretching, bending at the knee
and tipping over so its edges step, and it holds its key poses a beat, as
the official clips do.

Coordinates are grid units: x from the standing body's left edge, y up from
the ground; the body is 8 units wide and 6 tall on legs 2 long. Blocks can
be drawn behind Clawd (`back=True`). An action is {fps, frames, loop?}. One
with a loop plays its lead-in, goes round the loop for as long as it's asked
to, then plays the frames after the loop as its outro (Lottie marker "loop",
like the pet reads).

    tools/design_actions.py [name...]            write assets/actions/*.lottie.json
    tools/design_actions.py --preview [name...]  also build/previews/<name>.gif,
                                                 -sheet.png (every picture) and
                                                 -actual.png (as the screen shows it)
"""
import json
import math
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "assets", "actions")
PREVIEWS = os.path.join(ROOT, "build", "previews")

# Clawd-Laptop's canvas: 100 units to a grid unit, the standing body's left
# edge at x 936, the ground along the bottom.
CANVAS_W, CANVAS_H, BODY_LEFT = 2750, 1850, 936

# Clawd's own colours, as the Code tab's file has them.
BODY, SHADE, EYE = "#D87656", "#BE684D", "#000000"


def stacking(frames):
    """The layers `frames` need, topmost first, as (colour, behind Clawd).

    The format has one layer per colour, so each colour sits at one depth
    for the whole clip: wherever a block is drawn over an earlier one of
    another colour, its colour goes above. Blocks drawn behind Clawd go
    under all the rest."""
    keys, over = [], {}
    for frame in frames:
        for i, a in enumerate(frame.blocks):
            ka = a[4:6]
            if ka not in keys:
                keys.append(ka)
                over[ka] = set()
            for b in frame.blocks[i + 1:]:
                kb = b[4:6]
                if kb != ka and ka[1] == kb[1] and a[0] < b[0] + b[2] and b[0] < a[0] + a[2] \
                        and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]:
                    over[ka].add(kb)
    order = []
    for back in (False, True):
        left = [k for k in keys if k[1] == back]
        while left:
            # The last drawn of those with nothing left that must go over them.
            free = [k for k in left if not (over[k] & set(left))] or left
            order.append(free[-1])
            left.remove(free[-1])
    return order


class Frame:
    def __init__(self):
        self.blocks = []

    def add(self, x, y, w, h, color, back=False):
        """A block; `back` ones are drawn behind Clawd."""
        self.blocks.append((x, y, w, h, color, back))

    def sprite(self, rows, x, y, palette, px=0.5, back=False):
        """Character art, top row first, its bottom-left at (x, y); each
        character a pixel `px` units square, runs of one colour merged."""
        for r, line in enumerate(rows):
            py = y + (len(rows) - 1 - r) * px
            c = 0
            while c < len(line):
                color = palette.get(line[c])
                if color is None:
                    c += 1
                    continue
                run = c
                while run < len(line) and palette.get(line[run]) == color:
                    run += 1
                self.add(x + c * px, py, (run - c) * px, px, color, back)
                c = run


# MARK: Clawd

# The official palette, sampled from the Fable 5 film and the Code tab's
# file: Clawd's own colours and black, and for everything else the film's
# salmon, its lit cream, the laptop's gray and a near-black. What shines
# does it with a glow of cream dots, as the film's marquee lights up.
SALMON, CREAM, GRAY, INK = "#DC6263", "#FCEDCA", "#8B8B8B", "#303030"
# The amber of the film's NOW SHOWING lettering.
AMBER = "#E3A445"
# Darker tones for props' edges and undersides, and Claude FM's wood browns
# (its backpack, strap and bedroll).
GRAY_DARK, SALMON_DARK = "#666666", "#B24C4E"
# Near-black props' lit edges, so they still read on a dark desktop, and the
# shade under the amber hard hat's brim.
INK_LIGHT, AMBER_DARK = "#555555", "#B87E2C"
# Claude FM's reading Clawd: maroon glasses (a tone lighter on their rounded
# corners) and a blue book.
MAROON, MAROON_LIGHT = "#6A1D2C", "#C87A7F"
BLUE, BLUE_DARK = "#463F89", "#332D66"
WOOD, WOOD_DARK, WOOD_LIGHT = "#905418", "#5C300A", "#B4843A"

# How far below the top of the head a 2-by-2 claw hangs.
CLAW_DROP = {"rest": 4, "up": 3, "high": 2, "low": 5}


def snap(v):
    """To the nearest half unit."""
    return math.floor(v * 2 + 0.5) / 2


def turn_point(p, angle, pivot):
    a = math.radians(angle)
    dx, dy = p[0] - pivot[0], p[1] - pivot[1]
    return (pivot[0] + dx * math.cos(a) - dy * math.sin(a), pivot[1] + dx * math.sin(a) + dy * math.cos(a))


def rect_cells(x, y, w, h, angle=0.0, pivot=(0.0, 0.0)):
    """The half-unit cells a rectangle covers once turned `angle` degrees
    anticlockwise about `pivot`: those whose middles fall inside it."""
    if not angle:
        return {(x + i * 0.5, y + j * 0.5) for i in range(round(w * 2)) for j in range(round(h * 2))}
    a = math.radians(angle)
    ca, sa = math.cos(a), math.sin(a)
    corners = [turn_point(c, angle, pivot) for c in ((x, y), (x + w, y), (x, y + h), (x + w, y + h))]
    x0, x1 = math.floor(min(c[0] for c in corners) * 2) / 2, max(c[0] for c in corners)
    y0, y1 = math.floor(min(c[1] for c in corners) * 2) / 2, max(c[1] for c in corners)
    out = set()
    cy = y0
    while cy < y1:
        cx = x0
        while cx < x1:
            mx, my = cx + 0.25 - pivot[0], cy + 0.25 - pivot[1]
            bx, by = pivot[0] + mx * ca + my * sa, pivot[1] - mx * sa + my * ca
            if x <= bx < x + w and y <= by < y + h:
                out.add((cx, cy))
            cx += 0.5
        cy += 0.5
    return out


def turn_cells(cells, angle, pivot):
    """Cells turned `angle` degrees anticlockwise about `pivot`, redrawn
    cell by cell so the turned shape has no holes."""
    if not angle or not cells:
        return set(cells)
    cells = set(cells)
    a = math.radians(-angle)
    ca, sa = math.cos(a), math.sin(a)
    xs = [x for x, _ in cells]
    ys = [y for _, y in cells]
    pad = max(max(xs) - min(xs), max(ys) - min(ys)) / 2 + 1
    out = set()
    cy = math.floor((min(ys) - pad) * 2) / 2
    while cy < max(ys) + pad:
        cx = math.floor((min(xs) - pad) * 2) / 2
        while cx < max(xs) + pad:
            mx, my = cx + 0.25 - pivot[0], cy + 0.25 - pivot[1]
            bx, by = pivot[0] + mx * ca - my * sa, pivot[1] + mx * sa + my * ca
            if (math.floor(bx * 2) / 2, math.floor(by * 2) / 2) in cells:
                out.add((cx, cy))
            cx += 0.5
        cy += 0.5
    return out


def hold(frames, n=1):
    """Holds the last frame `n` frames longer: the official clips pause on
    their key poses rather than playing everything at an even 12 fps."""
    frames.extend([frames[-1]] * n)


def fill(f, cells, color, back=False):
    """Half-unit cells as blocks, each row's runs merged."""
    rows = {}
    for x, y in cells:
        rows.setdefault(y, []).append(x)
    for y, xs in sorted(rows.items()):
        xs.sort()
        start = prev = xs[0]
        for x in xs[1:] + [None]:
            if x is not None and abs(x - prev - 0.5) < 1e-9:
                prev = x
                continue
            f.add(start, y, prev + 0.5 - start, 0.5, color, back)
            if x is not None:
                start = prev = x


def sprite_cells(rows, x, y, ch="#"):
    """The half-unit cells of character art holding `ch`, bottom-left at (x, y)."""
    return {(x + c * 0.5, y + (len(rows) - 1 - r) * 0.5)
            for r, line in enumerate(rows) for c, k in enumerate(line) if k in ch}


def dot(f, x, y, color, back=False):
    """A quarter-unit dot in the middle of the half-unit cell at (x, y): the
    film draws dim and glowing things in dots finer than Clawd's pixels."""
    f.add(x + 0.125, y + 0.125, 0.25, 0.25, color, back)


def glow(f, cells, reach=1.5, color=CREAM):
    """Light round lit cells as round the film's marquee: a dot in every
    cell touching them, in every other one a cell further out, in every
    fourth out to `reach`."""
    lit = set(cells)
    near = {}
    n = round(reach * 2)
    for cx, cy in lit:
        for i in range(-n, n + 1):
            for j in range(-n, n + 1):
                p = (cx + i * 0.5, cy + j * 0.5)
                if p not in lit:
                    near[p] = min(near.get(p, 99), max(abs(i), abs(j)))
    for (px, py), d in sorted(near.items()):
        i, j = round(px * 2), round(py * 2)
        if d == 1 or (d == 2 and (i + j) % 2 == 0) or (d <= n and i % 2 == 0 and j % 2 == 0):
            dot(f, px, py, color)


class Head:
    """Where a drawn Clawd's head ended up, to put things on it."""

    def __init__(self, top, tilt, pivot, middle):
        self.top, self.tilt, self.pivot, self.middle = top, tilt, pivot, middle

    def at(self, x, y):
        """A point of the upright body, where the tilt has taken it."""
        return turn_point((x, y), self.tilt, self.pivot)

    def cells(self, x, y, w, h):
        """A rectangle on the upright body, turned with it."""
        return rect_cells(x, y, w, h, self.tilt, self.pivot)


def eye(f, x, y, style, middle=4.0):
    """An eye whose open 1-by-1 would have its bottom left at (x, y), all in
    Clawd's own pixels: the Code tab's open, "up", "wide" (a pixel taller)
    and "shut" (its wink bar), and "glee" (^) and "content" (v), which like
    the wink lean half a unit toward the middle of the face."""
    x0 = x if x + 0.5 < middle else x - 0.5
    if style == "open":
        f.add(x, y, 1, 1, EYE)
    elif style == "up":
        f.add(x, y + 0.5, 1, 1, EYE)
    elif style == "wide":
        f.add(x, y - 0.5, 1, 1.5, EYE)
    elif style == "shut":
        f.add(x0, y, 1.5, 0.5, EYE)
    elif style == "glee":
        f.add(x0 + 0.5, y + 0.5, 0.5, 0.5, EYE)
        f.add(x0, y, 0.5, 0.5, EYE)
        f.add(x0 + 1, y, 0.5, 0.5, EYE)
    elif style == "content":
        f.add(x0, y + 0.5, 0.5, 0.5, EYE)
        f.add(x0 + 1, y + 0.5, 0.5, 0.5, EYE)
        f.add(x0 + 0.5, y, 0.5, 0.5, EYE)


def clawd(f, bottom=2.0, height=6.0, width=8.0, dx=0.0, lift=0.0, tilt=0.0, arms=("rest", "rest"), eyes="open",
          look=(0.0, 0.0), side=False, blush=False, pivot=None):
    """Clawd in its own half-unit pixels, facing you or, `side`, in the
    three-quarter view the Code tab's Clawd types in: the back two units in
    shade, the far eye on the front edge, only the front claw showing.

    The body stands `bottom` up on its legs, `height` tall and `width` wide
    (squashed out past its feet, half a unit each side a unit), swayed `dx` over
    its feet (the knees bend to follow) or hopped `lift` off the ground.
    `tilt` turns it that many degrees anticlockwise about the middle of its
    underside, claws, eyes and all, and the legs reach down to the ground
    from wherever the body has got to: its edges step a pixel or two, the
    way the film and fan art show Clawd rocking. A claw (`arms`, left and
    right) is None, one of CLAW_DROP or a drop in units, "raised" (straight
    up the side past the top of the head, as the Code tab's Clawd holds its
    laptop aloft) or "reach" (thrown right up). `eyes` is a style of eye(),
    or a pair of them. Returns the Head.
    """
    y0 = lift + bottom
    top = y0 + height
    wide = (width - 8) / 2
    pivot = pivot or (dx + 4, y0)
    body = rect_cells(dx - wide, y0, width, height, tilt, pivot)
    fill(f, body, BODY)
    if side:
        fill(f, rect_cells(dx - wide, y0, 2, height, tilt, pivot), SHADE)
    claws = []
    for claw, x, w in ((None if side else arms[0], dx - 2 - wide, 2), (arms[1], dx + 8 + wide, 1.5 if side else 2)):
        if claw is None:
            continue
        if claw == "raised":
            rect = (x, top - 1, w, 2.5)
        elif claw == "reach":
            rect = (x + (0.5 if x < dx else 0), top - 1, 1.5, 3.5)
        else:
            rect = (x, top - CLAW_DROP.get(claw, claw), w, 2)
        claws.append(rect_cells(*rect, tilt, pivot))
        fill(f, claws[-1], BODY)
        if side:
            fill(f, rect_cells(rect[0], rect[1], 0.5, rect[3], tilt, pivot), SHADE)
    # Legs: planted where they stand, bent at the knee under a swayed body,
    # each half-column reaching up to the bottom of the body above it.
    columns = {}
    for x, y in body:
        columns[x] = min(columns.get(x, 99), y)
    for foot in (0, 2, 5, 7):
        color = SHADE if side and foot == 0 else BODY
        for k in (0, 0.5):
            upper = dx + foot + k
            reach = columns.get(upper, y0) - lift
            if reach <= 0:
                continue
            if dx and reach > 1:
                f.add(foot + k, lift, 0.5, 1, color)
                f.add(upper, lift + 1, 0.5, reach - 1, color)
            else:
                f.add(foot + k, lift, 0.5, reach, color)
    middle = dx + 4
    pair = eyes if isinstance(eyes, tuple) else (eyes, eyes)
    spots = ((dx + 3.5, top - 1.5), (dx + 7.5, top - 1.5)) if side else ((dx + 1.5, top - 1.5), (dx + 6.5, top - 1.5))
    for style, (cx, cy) in zip(pair, spots):
        cx, cy = turn_point((cx + look[0], cy + look[1]), tilt, pivot)
        eye(f, snap(cx - 0.5), snap(cy - 0.5), style, middle)
    if blush and not side:
        for bx in (dx + 0.5, dx + 6.5):
            cx, cy = turn_point((bx + 0.5, top - 2.75), tilt, pivot)
            f.add(snap(cx - 0.5), snap(cy - 0.25), 1, 0.5, SALMON)
    head = Head(top, tilt, pivot, middle)
    # Where the claws were drawn, for props held in them to leave out.
    head.claws = set().union(*claws)
    return head


def thinker(f, rub=False, eye_up=False, blink=False):
    """The Code tab's thinking pose: sunk half a unit, the far claw raised,
    the near one at the chin (`rub` drops it half a unit), one eye squinted
    and the other looking down, or `eye_up` to the side."""
    for x in (0, 2, 5, 7):
        f.add(x, 0, 1, 1.5, BODY)
    f.add(0, 1.5, 8, 6, BODY)
    f.add(-2, 4.5, 2, 2, BODY)
    low = 0.5 if rub else 0.0
    f.add(8, 3.0 - low, 1.5, 1.5, BODY)
    f.add(8, 2.5 - low, 1, 0.5, BODY)
    f.add(1, 4.5, 1.5, 0.5, EYE)
    if blink:
        f.add(5.5, 4.5, 1.5, 0.5, EYE)
    elif eye_up:
        f.add(6.5, 5.5, 1, 1, EYE)
    else:
        f.add(6, 4.5, 1, 1, EYE)


# MARK: Headphones

NOTE_ONE = [".##",
            ".#.",
            ".#.",
            "##.",
            "##."]
NOTE_TWO = [".####",
            ".#..#",
            ".#..#",
            "##.##",
            "##.##"]


def airpods_max(f, head, dx=0.0, out=0.0, lift=0.0):
    """AirPods Max in silver without the knit canopy, held `out` from the
    head and `lift` up: a gray cup on each side of the head, and the steel
    headband arching 1.5 units over it as a line of dots."""
    t = head.top + lift
    for x, inner in ((dx - 1 - out, dx - 0.5 - out), (dx + 8 + out, dx + 8 + out)):
        cushion = head.cells(inner, t - 2, 0.5, 2)
        fill(f, head.cells(x, t - 2, 1, 2) - cushion, GRAY)
        fill(f, cushion, GRAY_DARK)
    left, right = dx - 0.5 - out, dx + 8.5 + out
    mid, half = (left + right) / 2, (right - left) / 2
    seen = set()
    steps = max(8, round(math.pi * half * 2))
    for k in range(steps + 1):
        s = math.pi * k / steps
        x, y = head.at(mid - half * math.cos(s), t + 0.25 + 1.5 * math.sin(s))
        spot = (math.floor(x * 2) / 2, math.floor(y * 2) / 2)
        if spot not in seen:
            seen.add(spot)
            dot(f, *spot, GRAY)


def note(f, age, cup, art):
    """A note `age` frames out of the left (-1) or right (1) cup, rising and
    drifting outward; in its last frames it breaks up into dots."""
    sway = (0, 0.5, 0.5, 0, -0.5, -0.5)[age // 2 % 6]
    x = (-3.0 - age // 4 * 0.5 + sway) if cup < 0 else (9.5 + age // 4 * 0.5 + sway)
    y = 8.0 + age // 2 * 0.5
    if age < 9:
        f.sprite(art, x, y, {"#": CREAM})
    else:
        for cx, cy in sprite_cells(art, x, y):
            if (round(cx * 2) + round(cy * 2) + age) % 2 == 0:
                dot(f, cx, cy, CREAM)


def act_headphones():
    frames = []

    def pose(hold=None, out=0.0, lift=0.0, cups=True, **body):
        """`hold` puts both claws on the cups, that far below the head's
        top, stretched out after them; "overhead", they're raised straight up."""
        f = Frame()
        if hold == "overhead":
            body["arms"] = ("raised", "raised")
        elif hold is not None:
            body["arms"] = (None, None)
        head = clawd(f, **body)
        if hold is not None and hold != "overhead":
            reach, rise = math.floor(out * 2) / 2, math.floor(lift * 2) / 2
            dx = body.get("dx", 0.0)
            fill(f, head.cells(dx - 2 - reach, head.top - hold + rise, 2 + reach, 2), BODY)
            fill(f, head.cells(dx + 8, head.top - hold + rise, 2 + reach, 2), BODY)
        if cups:
            airpods_max(f, head, body.get("dx", 0.0), out, lift)
        frames.append(f)
        return f

    # On they go: held up over the head, spread and lowered on, then a
    # squash as they settle and a pop.
    pose(cups=False)
    pose(hold="overhead", out=0.5, lift=3.0, eyes="up")
    pose(hold=2, out=0.5, lift=1.5, eyes="up")
    pose(hold=2, lift=0.5, eyes="shut")
    pose(hold=2, bottom=1.5, eyes="shut")
    hold(frames)
    pose(height=6.5, eyes="wide")
    pose(eyes="content")
    pose(eyes="content")
    lead = len(frames)

    # Grooving, four beats of six frames: down on the beat, knees bent,
    # swayed and tipped toward the claw that goes up, back up straight; on
    # the last beat a hop. A note comes out of the cups on the first three.
    notes = [(0, -1, NOTE_ONE), (6, 1, NOTE_TWO), (12, -1, NOTE_TWO)]
    moves = []
    for way in (1, -1, 1):
        arms = ("low", "up") if way > 0 else ("up", "low")
        moves += [dict(dx=0.5 * way, bottom=1.5, tilt=-7 * way, arms=arms)] * 2
        moves += [dict(dx=0.5 * way, tilt=-3.6 * way, arms=arms), dict(), dict(), dict()]
    moves += [dict(bottom=1.5, arms=("low", "low"), eyes="glee"), dict(lift=1, arms=("up", "up"), eyes="glee"),
              dict(lift=1.5, arms=("high", "high"), eyes="glee", height=6.5), dict(lift=0.5, arms=("up", "up"), eyes="glee"),
              dict(bottom=1.5, eyes="glee"), dict(eyes="glee")]
    for i, move in enumerate(moves):
        f = pose(**{"eyes": "content", **move})
        for spawn, cup, art in notes:
            if 0 <= i - spawn < 12:
                note(f, i - spawn, cup, art)
    loop = (lead, len(frames) - 1)

    # Off they come: both claws lift them off over the head and toss them away.
    pose(eyes="open")
    pose(hold=2, eyes="open")
    pose(hold=2, lift=0.5, eyes="open")
    pose(height=6.5, hold="overhead", out=0.5, lift=2.5, eyes="glee")
    pose(height=6.5, arms=("high", "high"), eyes="glee", out=1.0, lift=5.5)
    pose(bottom=1.5, eyes="glee", cups=False)
    pose(eyes="glee", cups=False)
    pose(cups=False)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Laptop

# Clawd's own laptop, side on in front of it and as plain as the Code tab
# draws its one: a gray base with dark dots for keys, the lid leaning back
# from the far end, and a few cream dots of light off its screen.
LAPTOP_X = 8.5   # where the base starts, just in front of the claw


def laptop(f, open_=3.0, y=0.0, lit=True, flicker=0, tap=None, poof=False):
    """The laptop on the ground (or `y` up), its lid `open_` units tall (0
    shut); `tap` lights a key under the claw; `poof` is it going in dots."""
    x = LAPTOP_X
    base = rect_cells(x, y, 5, 1.0)
    lid = set()
    if open_ > 0:
        # Leaning back a pixel every 1.5 units as it rises from the hinge.
        for k in range(round(open_ * 2)):
            lid.add((x + 4.5 + (k // 3) * 0.5, y + 1.0 + k * 0.5))
    else:
        base |= rect_cells(x, y + 1.0, 5, 0.5)
    if poof:
        for cx, cy in sorted(base | lid):
            if round((cx + cy) * 2) % 2 == 0:
                dot(f, cx, cy, GRAY)
        return
    fill(f, base | lid, GRAY)
    if open_ > 0:
        for k in range(4):
            key = (x + 0.5 + k, y + 0.5)
            dot(f, *key, CREAM if tap == key else GRAY_DARK)
    if lit and open_ >= 3.0:
        # The screen's light, a few dots off the lid that change as it scrolls.
        for k, (lx, ly) in enumerate(sorted(lid)):
            if (k + flicker) % 2 == 0:
                dot(f, lx - 0.5, ly, CREAM)


def act_laptop():
    frames = []

    def pose(open_=3.0, lit=True, flicker=0, tap=None, laptop_y=0.0, show=True, poof=False, hold_=1, **body):
        f = Frame()
        body.setdefault("side", True)
        clawd(f, **body)
        if show:
            laptop(f, open_, laptop_y, lit, flicker, tap, poof)
        frames.extend([f] * hold_)
        return f

    # The laptop drops in shut; Clawd turns to it, crouches, opens it up and
    # the screen comes on; a crack of the claw, and to work.
    pose(show=False, side=False)
    pose(open_=0, laptop_y=4.0, lit=False, side=False, eyes="up")
    pose(open_=0, laptop_y=1.5, lit=False, side=False, eyes="up")
    pose(open_=0, lit=False, eyes="wide", arms=(None, "rest"), hold_=2)
    pose(open_=0, lit=False, bottom=1.5, dx=0.5, eyes="shut", arms=(None, "low"))
    pose(open_=1.5, lit=False, bottom=1.5, dx=0.5, arms=(None, 5.0))
    pose(open_=3.0, bottom=1.5, dx=0.5, eyes="wide", arms=(None, 5.5), hold_=2)
    pose(bottom=1.5, dx=0.5, eyes="glee", arms=(None, "high"))
    pose(bottom=1.5, dx=0.5, eyes="glee", arms=(None, "up"))
    lead = len(frames)

    # Typing: the claw tapping the keys, eyes on the screen with a glance
    # down at the keys now and then, the screen flickering as the text
    # scrolls; a pause to think, eyes up; then a burst with eyes on the keys
    # and a hard press of the last one.
    keys = [(LAPTOP_X + 0.5 + k, 0.5) for k in range(4)]
    for i in range(36):
        if 22 <= i < 28:
            pose(bottom=1.5, dx=0.5, arms=(None, 6.0), look=(0.0, 0.5), flicker=i // 6)
            continue
        fast = i >= 28
        down = (i % 2 == 0) if fast else (i // 2 % 2 == 0)
        tap = keys[(i * 3) % 4] if down else None
        glance = fast or i % 11 in (8, 9, 10)
        pose(bottom=1.0 if i == 35 else 1.5, dx=0.5, arms=(None, 6.5 if down else 6.0),
             look=(0.0, -0.5) if glance else (0.0, 0.0), eyes="shut" if i == 14 else "open", tap=tap, flicker=i // 6)
    loop = (lead, len(frames) - 1)

    # Done: sitting up, the lid shut, standing, the laptop gone in a puff.
    pose(bottom=1.5, dx=0.5, arms=(None, "low"), eyes="content")
    pose(open_=1.5, lit=False, bottom=1.5, dx=0.5, arms=(None, 5.0), eyes="content")
    pose(open_=0, lit=False, bottom=1.5, dx=0.5, arms=(None, "low"))
    pose(open_=0, lit=False, arms=(None, "rest"), eyes="glee")
    pose(open_=0, lit=False, poof=True, side=False, eyes="glee")
    pose(show=False, side=False)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Idea

BULB = [".###.",
        "#####",
        "#####",
        "#####",
        ".###.",
        ".ggg.",
        ".hhh."]
FLASH = ["..#..",
         "..#..",
         "#####",
         "..#..",
         "..#.."]


def bulb(f, x, y, lit=True, reach=1.5):
    """The bulb, 2.5 units wide and 3.5 tall: cream glass on a gray screw
    base, glowing when lit; out, its glass is only a dim ring of dots, as
    the film draws its unlit sign."""
    f.sprite(BULB, x, y, {"#": CREAM if lit else None, "g": GRAY, "h": GRAY_DARK})
    glass = sprite_cells(BULB, x, y)
    if lit:
        glow(f, glass, reach)
    else:
        for cx, cy in glass:
            if any((cx + i, cy + j) not in glass for i, j in ((0.5, 0), (-0.5, 0), (0, 0.5), (0, -0.5))):
                dot(f, cx, cy, GRAY)


def act_idea():
    frames = []
    bx, by = 2.5, 9.5  # where the bulb hangs, over the head

    def frame(**body):
        f = Frame(); clawd(f, **body); frames.append(f)
        return f

    frame()
    frame()
    # Mulling it over in the Code tab's thinking pose, eyes drifting up.
    for up in (False, False, True, True):
        f = Frame(); thinker(f, eye_up=up); frames.append(f)
    # Gathering itself, squashed flat and wide...
    frame(bottom=1.0, height=5.5, width=9, arms=("low", "low"), eyes="shut")
    # ...pop! Stretched tall, claw thrown up, a flash where the bulb will be.
    f = frame(bottom=2.5, height=6.5, arms=("rest", "reach"), eyes="wide")
    f.sprite(FLASH, bx, by + 0.5, {"#": CREAM})
    glow(f, sprite_cells(FLASH, bx, by + 0.5), 1.0)
    hold(frames)
    # Off the ground, the bulb lit; down again, delighted.
    f = frame(lift=0.5, arms=("rest", "reach"), eyes="wide"); bulb(f, bx, by + 0.5)
    f = frame(arms=("rest", "reach"), eyes="glee"); bulb(f, bx, by)
    hold(frames)
    # Bouncing on the spot and rocking side to side, the light pulsing.
    for i in range(10):
        up = (i // 2) % 2 == 0
        way = 1 if (i // 4) % 2 == 0 else -1
        f = frame(bottom=2.5 if up else 2.0, tilt=0 if up else 7 * way, arms=("rest", "reach"), eyes="glee")
        bulb(f, bx, by + (0.5 if up else 0), reach=1.5 if up else 1.0)
    # It flickers and goes out; the claw comes down.
    f = frame(arms=("rest", "high")); bulb(f, bx, by, lit=False)
    f = frame(arms=("rest", "high")); bulb(f, bx, by)
    f = frame(arms=("rest", "up")); bulb(f, bx, by, lit=False)
    f = frame()
    for x, y in ((bx + 0.5, by + 1.0), (bx + 1.5, by + 2.0), (bx + 2.0, by + 0.5)):
        dot(f, x, y, GRAY)
    frame()
    frame()
    return {"fps": 12, "frames": frames}


# MARK: Sunglasses

SHADES = ["llllllllllllllllll",
          ".#######..#######.",
          ".#######..#######.",
          "..#####....#####.."]
SPARKLE = [".#.",
           "###",
           ".#."]


def sunglasses(f, head, drop=0.0, tilt=None, glint=None, shift=0.0):
    """Over Clawd's eyes, their top along the top of its head, or `drop`
    further down its face (negative: up on its head or thrown), turned with
    the head or by `tilt` of their own; `glint` is how far across the
    lenses a glint of light has got, in half units."""
    x, y = -0.5 + shift, head.top - 2.0 - drop
    frame = sprite_cells(SHADES, x, y)
    light = set()
    if glint is not None:
        for r, line in enumerate(SHADES[1:], start=1):
            for c, ch in enumerate(line):
                if ch == "#" and c + r - glint in (0, 1):
                    light.add((x + c * 0.5, y + (len(SHADES) - 1 - r) * 0.5))
    angle = head.tilt if tilt is None else tilt
    pivot = head.pivot if tilt is None else (4 + shift, y + 1.0)
    fill(f, turn_cells(frame - light, angle, pivot), INK)
    fill(f, turn_cells(sprite_cells(SHADES, x, y, "l"), angle, pivot), INK_LIGHT)
    fill(f, turn_cells(light, angle, pivot), CREAM)


def act_sunglasses():
    frames = []

    def pose(glasses=True, look=(0.0, 0.0), eyes="open", drop=0.0, tilt_glasses=None, glint=None, shift=0.0,
             **body):
        f = Frame()
        on_face = glasses and -1.5 < drop < 1.5
        head = clawd(f, eyes=None if on_face else eyes, look=look, **body)
        if glasses:
            sunglasses(f, head, drop, tilt_glasses, glint, shift)
        frames.append(f)
        return f, head

    pose(glasses=False)
    pose(glasses=False)
    # Reaching up for them and pulling them down onto the face.
    pose(arms=("rest", "up"), eyes="up", glasses=False)
    pose(arms=("rest", "reach"), eyes="up", glasses=False)
    pose(arms=("rest", "reach"), eyes="up", drop=-3.5, tilt_glasses=10)
    pose(arms=("rest", "up"), drop=0.5, tilt_glasses=5)
    # On: a squash as they click into place, then up with both claws.
    pose(bottom=1.5, arms=("rest", "up"))
    hold(frames)
    pose(height=6.5, arms=("high", "high"))
    # Leaning back, cool; a glint sweeps across the lenses and sparkles off the corner.
    pose(arms=("low", "low"), tilt=4)
    pose(arms=("low", "low"), tilt=7)
    for g in (-2, 3, 8, 13, 18, 23):
        pose(arms=("low", "low"), tilt=7, glint=g)
    for art in (SPARKLE, [".#.", "#.#", ".#."]):
        f, head = pose(arms=("low", "low"), tilt=7)
        sx, sy = head.at(8.25, head.top - 0.25)
        f.sprite(art, snap(sx - 0.75), snap(sy - 0.75), {"#": CREAM})
    pose(arms=("low", "low"), tilt=7)
    pose(arms=("low", "low"), tilt=4)
    # Sliding them down the nose to peek over, a look each way, and back up.
    pose(arms=("low", "low"), drop=0.5)
    for look in ((0, 0), (0, 0), (-0.5, 0), (-0.5, 0), (0.5, 0), (0.5, 0)):
        pose(arms=("low", "low"), drop=1.5, look=look)
    pose(arms=("low", "up"), drop=1.5)
    pose(arms=("low", "rest"))
    # A cool nod, then off: pushed up the head and flung away, with a wink.
    pose(bottom=1.5, arms=("low", "low"))
    pose(arms=("low", "low"))
    pose(arms=("low", "low"))
    pose(arms=("low", "up"), drop=-0.5)
    pose(arms=("low", "high"), drop=-2.0, tilt_glasses=8)
    pose(height=6.5, arms=("low", "reach"), eyes="glee", drop=-4.5, tilt_glasses=20, shift=1.5)
    pose(height=6.5, arms=("low", "reach"), eyes="glee", drop=-7.5, tilt_glasses=35, shift=3.5)
    pose(eyes="glee", glasses=False)
    for _ in range(3):
        pose(eyes=("shut", "open"), glasses=False)
    pose(glasses=False)
    pose(glasses=False)
    return {"fps": 12, "frames": frames}


# MARK: Bubbles

WAND = ["###",
        "#.#",
        "###"]


def circle(r):
    """The pixels of a circle `r` pixels round the pixel at (0, 0): the
    midpoint algorithm, so it's symmetric and one pixel thick."""
    points = set()
    x, y, d = 0, r, 1 - r
    while x <= y:
        for px, py in ((x, y), (y, x)):
            points |= {(px, py), (-px, py), (px, -py), (-px, -py)}
        x += 1
        if d < 0:
            d += 2 * x + 1
        else:
            y -= 1
            d += 2 * (x - y) + 1
    return points


def bubble(f, x, y, r):
    """A soap bubble round the pixel at (x, y), `r` of Clawd's pixels to its
    rim: see-through, so its rim is a ring of cream dots, and once it's big
    enough a cream pixel of light shows in its top left."""
    for i, j in circle(r):
        dot(f, x + i * 0.5, y + j * 0.5, CREAM)
    if r >= 3:
        f.add(x - (r - 1) * 0.5, y + (r - 2) * 0.5, 0.5, 0.5, CREAM)


def pop(f, x, y, r, stage):
    """A bubble `r` pixels round bursting: dots flung out, then fewer, further."""
    for k in range(8 if stage == 0 else 6):
        a = math.radians(k * (45 if stage == 0 else 60) + 20 * stage)
        reach = (r + (1.5 if stage == 0 else 3)) * 0.5
        dot(f, snap(x + reach * math.cos(a)), snap(y + reach * math.sin(a)), CREAM)


def act_bubbles():
    frames = []

    def pose(claw="rest", ring=True, **body):
        f = Frame()
        head = clawd(f, side=True, arms=(None, claw), **body)
        if ring and claw is not None:
            # The wand's ring rests on top of the claw, in front of the face.
            x, y = head.at(8.75, head.top - CLAW_DROP.get(claw, claw) + 2.75)
            f.sprite(WAND, snap(x - 0.75), snap(y - 0.75), {"#": SALMON})
        frames.append(f)
        return f, head

    pose(ring=False)
    pose(claw="low")
    pose()
    # A breath in, leaning back; then blowing, leaning in, the bubble swelling out of the ring.
    pose(height=6.5, eyes="wide", tilt=5)
    pose(height=6.5, eyes="wide", tilt=5)
    for r in (1, 1, 2, 2, 3, 3):
        f, head = pose(bottom=1.5, eyes="shut", tilt=-4)
        bubble(f, 10.0 + r * 0.5, head.top - 1.5 + r // 2 * 0.5, r)
    # Off it floats, wobbling up and away, Clawd watching it go; a second
    # breath sends a little one after it.
    path = [(11.5, 7.0), (11.5, 7.5), (12.0, 8.0), (12.0, 8.5), (12.5, 9.0), (12.5, 9.5), (13.0, 10.0),
            (13.0, 10.5), (13.5, 11.0), (13.5, 11.5), (13.5, 12.0), (14.0, 12.5), (14.0, 13.0), (14.0, 13.5)]
    small = [(10.0, 7.0), (10.5, 7.5), (10.5, 8.5), (11.0, 9.0), (11.0, 10.0), (11.0, 10.5)]
    for k, (cx, cy) in enumerate(path):
        if 3 <= k <= 4:
            f, head = pose(bottom=1.5, eyes="shut", tilt=-4)
        else:
            f, head = pose(eyes="open" if k < 2 else "up" if k < 7 else "glee", tilt=3 if 5 <= k < 9 else 0)
        bubble(f, cx, cy, 3)
        if 5 <= k < 5 + len(small):
            bubble(f, *small[k - 5], 1)
    # Pop! Clawd jumps at it, then giggles.
    cx, cy = 14.0, 14.0
    f, head = pose(eyes="wide", lift=0.5, tilt=5); pop(f, cx, cy, 3, 0)
    f, head = pose(eyes="wide"); pop(f, cx, cy, 3, 1)
    for k in range(4):
        pose(bottom=1.5 if k % 2 == 0 else 2.0, eyes="glee", tilt=(-5, 0, 5, 0)[k])
    pose(eyes="glee", claw="low")
    pose(ring=False)
    pose(ring=False)
    return {"fps": 12, "frames": frames}


# MARK: Love

HEARTS = {
    5: ["##.##",
        "#####",
        ".###.",
        "..#.."],
    7: [".##.##.",
        "#######",
        "#######",
        ".#####.",
        "..###..",
        "...#..."],
    9: [".###.###.",
        "#########",
        "#########",
        "#########",
        ".#######.",
        "..#####..",
        "...###...",
        "....#...."],
}
HEART_TINY = ["#.#",
              "###",
              ".#."]


def heart(f, size, bottom, shine=False):
    """A salmon heart `size` pixels wide, its point at `bottom`, all of them
    centred a quarter unit right of Clawd's middle; `shine` lights it up."""
    x = 4.25 - size / 4
    f.sprite(HEARTS[size], x, bottom, {"#": SALMON})
    if shine:
        glow(f, sprite_cells(HEARTS[size], x, bottom), 1.0)


def act_love():
    frames = []

    def pose(**body):
        f = Frame()
        head = clawd(f, **{"height": 6.5, "arms": ("raised", "raised"), "eyes": "glee", "blush": True, **body})
        frames.append(f)
        return f, head

    f = Frame(); clawd(f); frames.append(f)
    f = Frame(); clawd(f); frames.append(f)
    # Gathering itself, then up go the claws, straight up the sides.
    f = Frame(); clawd(f, bottom=1.5, arms=("low", "low"), eyes="shut"); frames.append(f)
    pose(arms=("high", "high"), eyes="open", blush=False)
    pose(blush=False)
    # A heart pops out between the claws: small, too big, settling.
    for size, lift in ((5, 1.5), (9, 2.0), (7, 2.5)):
        f, head = pose()
        heart(f, size, head.top + lift, shine=size == 9)
        if size == 9:
            hold(frames)
    # Two heartbeats, Clawd rocking one way then the other on each.
    for way in (1, -1):
        for size, bottom, tilt in ((9, 1.5, 7 * way), (7, 2.0, 4 * way), (9, 1.5, 7 * way), (7, 2.0, 0),
                                   (7, 2.0, 0), (7, 2.0, 0)):
            f, head = pose(bottom=bottom, tilt=tilt)
            heart(f, size, 8.5 + (2.0 if size == 9 else 2.5), shine=size == 9)
    # Off it floats and breaks into little hearts; the claws come down.
    f, head = pose(); heart(f, 7, head.top + 3.0)
    f, head = pose(); heart(f, 9, head.top + 3.5, shine=True)
    for k in range(7):
        f = Frame()
        if k < 2:
            clawd(f, height=6.5, arms=("raised", "raised"), eyes="glee", blush=True)
        elif k < 4:
            clawd(f, arms=("high", "high"), eyes="glee", blush=True)
        else:
            clawd(f, eyes="glee" if k < 6 else "open")
        frames.append(f)
        if k < 5:
            for n, way in enumerate((-1, 0, 1)):
                x = 3.5 + way * (2.0 + k * 0.5)
                y = 12.0 + k * 0.5 + (0.5 if way == 0 else 0)
                if k < 3:
                    f.sprite(HEART_TINY, x, y, {"#": SALMON})
                else:
                    for cx, cy in sprite_cells(HEART_TINY, x, y):
                        dot(f, cx, cy, SALMON)
    return {"fps": 12, "frames": frames}


# MARK: Dizzy

SPIRAL_EYE = ["#####",
              "#...#",
              "#.#.#",
              "#.###",
              "#...."]
STAR = [".#.",
        "###",
        ".#."]
SWEAT = [".#",
         "##",
         "##"]


def rotate(rows, turns):
    """Character art turned a quarter clockwise `turns` times."""
    for _ in range(turns % 4):
        rows = ["".join(row[c] for row in reversed(rows)) for c in range(len(rows[0]))]
    return rows


def spiral_eyes(f, head, dx, turn):
    """Spinning spirals 2.5 units across where the eyes are."""
    art = rotate(SPIRAL_EYE, turn)
    for cx in (dx + 1.75, dx + 6.25):
        x, y = head.at(cx, head.top - 1.75)
        f.sprite(art, snap(x - 1.25), snap(y - 1.25), {"#": EYE})


def star_halo(f, cx, cy, turn, spread=0.0):
    """Three stars circling over the head, `turn` sixteenths round: the near
    ones cream crosses, the far ones single dots. `spread` flings them out."""
    for k in range(3):
        a = math.radians(turn * 22.5 + k * 120)
        x = cx + (4.5 + spread) * math.cos(a)
        y = cy + (1.0 + spread * 0.5) * math.sin(a) + spread * 0.5
        if math.sin(a) < 0:
            f.sprite(STAR, snap(x - 0.75), snap(y - 0.75), {"#": CREAM})
        else:
            dot(f, math.floor(x * 2) / 2, math.floor(y * 2) / 2, CREAM)


def act_dizzy():
    frames = []

    def frame(**body):
        f = Frame(); head = clawd(f, **body); frames.append(f)
        return f, head

    # The landing: flattened wide, feet splayed, dust puffing out each side.
    f, head = frame(bottom=1.0, height=4.5, width=9, arms=("low", "low"), eyes="shut")
    for x, y in ((-2.0, 0), (-2.5, 0.5), (10.0, 0), (10.5, 0.5)):
        dot(f, x, y, GRAY)
    f, head = frame(height=6.5, arms=("up", "up"), eyes="wide")
    for x, y in ((-3.0, 0.5), (-3.5, 1.0), (11.0, 0.5), (11.5, 1.0)):
        dot(f, x, y, GRAY)
    for j in (2, 3):
        f, head = frame(arms=("low", "low"), eyes=None)
        spiral_eyes(f, head, 0, j); star_halo(f, 4, head.top + 1.75, j - 4)
    lead = len(frames)

    # Reeling: swaying and tipping over buckling knees, eyes spinning, stars going round.
    sway = [0, 0, -1, -1, -1, -1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0]
    knees = [2, 2, 2, 1.5, 1.5, 2, 2, 2, 2, 2, 2, 1.5, 1.5, 2, 2, 2]
    for i in range(16):
        way = sway[i]
        arms = ("low", "rest") if way < 0 else ("rest", "low") if way > 0 else ("low", "low")
        f, head = frame(dx=0.5 * way, bottom=knees[i], tilt=-7 * way, arms=arms, eyes=None)
        spiral_eyes(f, head, 0.5 * way, i // 2)
        star_halo(f, 4 + 0.5 * way, head.top + 1.75, i)
    loop = (lead, len(frames) - 1)

    # Shaking it off: a quick shake of the head flings the stars away, then
    # a drop of sweat.
    for k, way in enumerate((-1, 1, -1, 1)):
        f, head = frame(tilt=7 * way, eyes="shut")
        if k < 2:
            star_halo(f, 4, head.top + 1.75, 16 + k * 2, spread=1.5 + k * 2)
    for k in range(4):
        f, head = frame()
        if k < 3:
            f.sprite(SWEAT, 8.5, head.top - 1.5 - k * 0.5, {"#": GRAY})
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Confetti

BANG = ["..#..",
        "#.#.#",
        ".###.",
        "#.#.#",
        "..#.."]


# A party popper held pointing up and right: salmon and cream bands up the
# cone from its tip, bottom left, to its cream mouth.
POPPER = ["...c..",
          "..ccc.",
          "..sccc",
          ".cssc.",
          "scc...",
          "ss...."]

CONFETTI = [SALMON, CREAM]


def confetti_pieces(seed=7, count=14):
    """Paper confetti fired from the popper's mouth, as per-frame positions:
    fast out of the mouth, slowed by the air, fluttering down."""
    import random
    rng = random.Random(seed)
    pieces = []
    for n in range(count):
        angle = math.radians(rng.uniform(35, 135))
        speed = rng.uniform(1.8, 2.9)
        vx, vy = speed * math.cos(angle), speed * math.sin(angle)
        x, y = 0.0, 0.0
        phase = rng.uniform(0, 2 * math.pi)
        fall = rng.uniform(0.24, 0.34)
        path = []
        for t in range(48):
            path.append((x + 0.3 * math.sin(phase + t * 0.7) * min(1, t / 5), y))
            vx *= 0.74
            vy = max(vy * 0.74 - 0.12, -fall)
            x += vx
            y += vy
        pieces.append({"path": path, "color": CONFETTI[n % len(CONFETTI)], "back": n % 3 == 0,
                       "spin": rng.randrange(4), "streamer": n % 7 == 3, "gone": rng.randrange(32, 44)})
    return pieces


def draw_piece(f, piece, x, y, t):
    x, y = math.floor(x * 2) / 2, math.floor(y * 2) / 2
    if piece["streamer"]:
        # A curly ribbon, its kinks shifting as it falls.
        for k in range(3):
            f.add(x + ((k + t) % 2) * 0.5, y - k * 0.5, 0.5, 0.5, piece["color"], piece["back"])
        return
    # Paper tumbling: a flat square, then edge on, a glint of a dot.
    if (t + piece["spin"]) % 2 == 0:
        f.add(x, y, 0.5, 0.5, piece["color"], piece["back"])
    else:
        dot(f, x, y, piece["color"], piece["back"])


def act_confetti():
    frames = []

    def pose(claw="up", popper=True, recoil=0.0, **body):
        f = Frame()
        head = clawd(f, side=True, arms=(None, claw), **body)
        if popper and claw is not None:
            x, y = head.at(9.0, head.top - CLAW_DROP.get(claw, claw) + 1.5)
            f.sprite(POPPER, snap(x - recoil), snap(y), {"s": SALMON, "c": CREAM})
        frames.append(f)
        return f, head

    pose(claw="rest", popper=False)
    pose(claw="rest", popper=False)
    # Up with the popper, braced for it...
    pose(eyes="up")
    pose(bottom=1.5, eyes="shut", tilt=-4)
    pose(bottom=1.5, eyes="shut", tilt=-4)
    # ...bang! Knocked back, then a shower of confetti and hopping for joy.
    f, head = pose(height=6.5, eyes="wide", dx=-0.5, tilt=7, recoil=0.5)
    f.sprite(BANG, 10.5, 8.0, {"#": CREAM})
    glow(f, sprite_cells(BANG, 10.5, 8.0), 1.0)
    hold(frames)
    mouth_x, mouth_y = 11.0, 9.0
    pieces = confetti_pieces()
    hops = {3: 0.5, 4: 1.0, 5: 0.5, 9: 0.5, 10: 1.0, 11: 0.5, 16: 0.5, 17: 1.0, 18: 0.5}
    tips = {4: 4, 10: -4, 17: 4}
    landed = {}
    for t in range(44):
        f, head = pose(claw="up" if t < 26 else "rest", eyes="glee" if t < 36 else "open", lift=hops.get(t, 0.0),
                       bottom=1.5 if t in (6, 12, 19) else 2.0, tilt=tips.get(t, 0))
        if t == 0:
            f.sprite(SPARKLE, 10.75 - 0.25, 8.5, {"#": CREAM})
        for n, piece in enumerate(pieces):
            if t >= piece["gone"]:
                continue
            if n in landed:
                x, on_head, since = landed[n]
                if t - since < 10:
                    draw_piece(f, piece, x, head.top if on_head else 0.0, since)
                continue
            px, py = piece["path"][t]
            x, y = mouth_x + px, mouth_y + py
            if not piece["back"] and not piece["streamer"] and 0.5 <= x <= 7.5 and head.top <= y < head.top + 0.4 and t > 4:
                landed[n] = (x, True, t)
                y = head.top
            elif y <= 0:
                landed[n] = (x, False, t)
            draw_piece(f, piece, x, max(y, 0.0), t)
    pose(claw="rest", popper=False)
    return {"fps": 12, "frames": frames}


# MARK: Thinking

# A speech bubble lit like the film's marquee: cream, with salmon dots.
SAY = [".#########.",
       "###########",
       "###########",
       "###########",
       ".#########.",
       "..##.......",
       "..#........"]
SAY_SMALL = [".#####.",
             "#######",
             "#######",
             ".#####.",
             ".##....",
             ".#....."]


def act_thinking():
    frames = []
    bx, by = 4.0, 8.0  # the bubble's bottom left, the tip of its tail

    def frame(**kw):
        f = Frame(); thinker(f, **kw); frames.append(f)
        return f

    f = Frame(); clawd(f); frames.append(f)
    f = Frame(); clawd(f, bottom=1.5, arms=("up", "low")); frames.append(f)
    frame()
    frame(rub=True)
    # The bubble pops up, small then full.
    f = frame(); f.sprite(SAY_SMALL, bx + 0.5, by + 0.5, {"#": CREAM})
    f = frame(rub=True); f.sprite(SAY, bx, by, {"#": CREAM})
    lead = len(frames)

    # Mulling it over: the dots rising in turn, the claw rubbing the chin, a
    # look to the side and a blink.
    for i in range(24):
        f = frame(rub=i // 3 % 2 == 1, eye_up=12 <= i < 18, blink=i == 21)
        f.sprite(SAY, bx, by, {"#": CREAM})
        for k in range(3):
            up = 0.5 if 3 * k <= i % 12 < 3 * k + 3 else 0.0
            f.add(bx + 1.5 + k, by + 2.0 + up, 0.5, 0.5, SALMON)
    loop = (lead, len(frames) - 1)

    # Done thinking: the bubble shrinks and breaks up, the claws come down.
    f = frame(); f.sprite(SAY_SMALL, bx + 0.5, by + 0.5, {"#": CREAM})
    f = frame()
    for cx, cy in sprite_cells(SAY_SMALL, bx + 0.5, by + 0.5):
        if round(cx * 2) % 2 == 0 and round(cy * 2) % 2 == 0:
            dot(f, cx, cy, CREAM)
    f = Frame(); clawd(f, bottom=1.5, arms=("up", "low")); frames.append(f)
    f = Frame(); clawd(f); frames.append(f)
    f = Frame(); clawd(f); frames.append(f)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Detective

TOP_HAT = ["...lllllllll...",
           "...l########...",
           "...l########...",
           "...sssssssss...",
           "###############"]
# A magnifying glass: a gray rim round the lens, 3 units across.
LENS_RIM = ["..##..",
            ".#..#.",
            "#....#",
            "#....#",
            ".#..#.",
            "..##.."]
QUESTION = [".###.",
            "#...#",
            "...#.",
            "..#..",
            ".....",
            "..#.."]


def top_hat(f, head, x=1.0, lift=0.0):
    """A top hat with a salmon band on Clawd's head, lit along its top and
    left edge, turned with it."""
    for key, color in (("#", INK), ("l", INK_LIGHT), ("s", SALMON)):
        fill(f, turn_cells(sprite_cells(TOP_HAT, x, head.top + lift, key), head.tilt, head.pivot), color)


def act_detective():
    frames = []

    def pose(glass=None, hat=0.0, **body):
        """`glass` is where the lens's middle is, or None; `hat` lifts the hat."""
        f = Frame()
        head = clawd(f, side=True, arms=(None, "low" if glass else "rest"),
                     eyes=("open", None) if glass else body.pop("eyes", "open"), **body)
        if hat is not None:
            top_hat(f, head, lift=hat)
        if glass:
            gx, gy = head.at(*glass)
            x, y = snap(gx - 1.5), snap(gy - 1.5)
            # Behind the lens the far eye looks big; a dot of light on the glass.
            f.add(x + 1.0, y + 0.75 - 0.25, 1.0, 1.5, EYE)
            dot(f, x + 1.0, y + 2.0, CREAM)
            f.sprite(LENS_RIM, x, y, {"#": GRAY})
            # The handle runs down to the claw.
            f.add(x + 2.5, y - 0.5, 0.5, 0.5, GRAY)
            f.add(x + 3.0, y - 1.0, 0.5, 0.5, GRAY)
        frames.append(f)
        return f, head

    pose(hat=None)
    pose(hat=3.0, eyes="up")
    pose(hat=1.0, eyes="up")
    pose(hat=0.0, bottom=1.5, eyes="shut")
    hold(frames)
    pose(hat=0.0, eyes="open")
    pose(glass=(7.5, 5.5))
    hold(frames)
    lead = len(frames)

    # Peering about: in close, down at the ground, back up, then up high;
    # now and then a question pops up.
    looks = [((7.5, 6.5), -4)] * 6 + [((8.0, 5.5), -7)] * 6 + [((7.5, 6.5), 0)] * 6 + [((7.5, 7.0), 4)] * 6
    for i, (glass, tilt) in enumerate(looks):
        f, head = pose(glass=glass, tilt=tilt, bottom=2.0 if i % 6 < 3 else 1.5 if tilt < -5 else 2.0)
        if 18 <= i < 24:
            f.sprite(QUESTION, -1.5, head.top + 2.0 + (0.5 if i % 2 else 0), {"#": CREAM})
    loop = (lead, len(frames) - 1)

    pose(glass=(7.5, 5.5))
    pose(hat=0.0)
    pose(hat=1.5, eyes="up")
    pose(hat=4.0, eyes="up")
    pose(hat=None)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Hard hat

HARD_HAT = ["......######......",
            "...############...",
            "..######cc######..",
            "dddddddddddddddddd"]
WRENCH = ["#.#",
          "###",
          ".#.",
          ".#.",
          ".#."]


def hard_hat(f, head, lift=0.0):
    """An amber hard hat with a cream badge and a darker brim, turned with
    the head."""
    x, y = -0.5, head.top + lift
    for key, color in (("#", AMBER), ("d", AMBER_DARK), ("c", CREAM)):
        fill(f, turn_cells(sprite_cells(HARD_HAT, x, y, key), head.tilt, head.pivot), color)


def act_hardhat():
    frames = []

    def pose(hat=0.0, wrench=None, sparks=0, **body):
        f = Frame()
        head = clawd(f, **body)
        if hat is not None:
            hard_hat(f, head, lift=hat)
        if wrench is not None:
            # The wrench in the right claw, jaws up, raised or brought down.
            x, y = head.at(10.0, head.top - 2.0 + wrench)
            art = WRENCH if wrench >= 0 else rotate(WRENCH, 1)
            f.sprite(art, snap(x - 0.75), snap(y), {"#": GRAY})
            for k in range(sparks):
                a = math.radians(30 + k * 50)
                dot(f, snap(x + 1.5 * math.cos(a)), snap(y - 0.5 + 1.5 * math.sin(a)), CREAM)
        frames.append(f)
        return f, head

    pose(hat=None)
    pose(hat=3.5, eyes="up")
    pose(hat=1.5, eyes="up")
    pose(hat=0.0, bottom=1.5, eyes="shut")
    pose(height=6.5, eyes="wide", arms=("rest", "up"), wrench=1.0)
    pose(arms=("rest", "up"), wrench=1.0)
    lead = len(frames)

    # Hard at it: the wrench swung up and brought down, a squash and a
    # spray of sparks on every blow, leaning into it.
    swing = [dict(arms=("rest", "high"), wrench=2.0, tilt=3), dict(arms=("rest", "high"), wrench=2.0, tilt=3),
             dict(arms=("rest", "up"), wrench=0.5, tilt=0),
             dict(arms=("rest", "rest"), wrench=-1.0, tilt=-5, bottom=1.5, sparks=4, eyes="shut"),
             dict(arms=("rest", "rest"), wrench=-1.0, tilt=-5, bottom=1.5, sparks=2, eyes="shut"),
             dict(arms=("rest", "up"), wrench=0.5, tilt=0)]
    for i in range(18):
        pose(**swing[i % 6])
    loop = (lead, len(frames) - 1)

    pose(arms=("rest", "up"), wrench=1.0)
    pose(hat=0.0, eyes="glee")
    pose(hat=2.0, eyes="glee", height=6.5)
    pose(hat=None, eyes="glee")
    pose(hat=None)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Sailboat

# A chunky wooden hull, bow to the right, planked like Claude FM's props:
# a lit gunwale, planks with dark seams, a dark keel.
HULL = ["........................cccc",
        "cccccccccccccccccccccccccccc",
        "d##########################d",
        "dddddddddddddddddddddddddddd",
        ".d########################d.",
        "..dddddddddddddddddddddddd.."]
# How high the gunwale is, where the mast stands and Clawd sits down to.
HULL_TOP = 2.5
SAILS = [["#",
          "#",
          "#s",
          "#cc",
          "#sss",
          "#cccc"],
         ["#s",
          "#cc",
          "#sss",
          "#cccc",
          "#sssss",
          "#cccccc"],
         ["#s",
          "#cc",
          "#ssss",
          "#ccccc",
          "#ssssss",
          "#ccccccc"]]


def boat(f, x, y, sail=None, tilt=0.0, sink=0):
    """The boat with its bottom left at (x, y), 14 units long: a wooden
    hull in Claude FM's browns, lit along its rim and dark along its keel,
    that Clawd sits down in, and at the bow a dark wooden mast with, `sail`
    0 to 2 as it fills, a sail striped salmon and cream; `sink` breaks it up
    into dots."""
    pivot = (x + 7, y)
    parts = [(sprite_cells(HULL, x, y, key), color) for key, color in (("#", WOOD), ("d", WOOD_DARK), ("c", WOOD_LIGHT))]
    if sail is not None:
        art = SAILS[sail]
        top = y + HULL_TOP + len(art) * 0.5
        mast = {(x + 12.0, y + HULL_TOP + k * 0.5) for k in range(len(art) + 1)}
        cells = {(x + 12.0 + c * 0.5, top - r * 0.5) for r, line in enumerate(art) for c, ch in enumerate(line)
                 if ch in "cs"}
        stripes = {cell for cell in cells if art[round((top - cell[1]) * 2)][round((cell[0] - x - 12.0) * 2)] == "s"}
        parts += [(mast, WOOD_DARK), (cells - stripes, CREAM), (stripes, SALMON)]
    for cells, color in parts:
        cells = turn_cells(cells, tilt, pivot)
        if sink:
            for cx, cy in cells:
                if (round(cx * 2) + round(cy * 2) + sink) % 2 == 0:
                    dot(f, cx, cy, color)
        else:
            fill(f, cells, color)


def waves(f, t, y=0.0):
    """Dotted waves under the boat, rolling back as it sails on."""
    for k in range(12):
        x = -3.0 + ((k * 1.5 - t * 0.5) % 18)
        dot(f, snap(x), y + (0.5 if (k + t // 2) % 2 else 0.0), CREAM)


def act_sailboat():
    frames = []
    bx = -2.5  # where the boat's stern is

    def frame(**body):
        f = Frame(); head = clawd(f, **body); frames.append(f)
        return f, head

    def aboard(bob=0.0, tilt=0.0, **body):
        """Sitting down in the boat, its legs out of sight below the rim."""
        return frame(**{"bottom": 1.5, "lift": bob, "tilt": tilt, "pivot": (bx + 7, bob), **body})

    frame()
    frame(bottom=1.5, eyes="shut")
    # A hop into the boat as it slides in underneath.
    f, head = frame(lift=1.5, eyes="wide", arms=("up", "up")); boat(f, bx, 0.0)
    f, head = frame(lift=1.0, eyes="wide", arms=("up", "up")); boat(f, bx, 0.0)
    for k, sail in enumerate((None, 0, 1, 2)):
        f, head = aboard(eyes="glee", bottom=1.0) if k == 0 else aboard(eyes="glee")
        boat(f, bx, 0.0, sail)
        waves(f, k)
        if sail == 2:
            hold(frames)
    # Under sail: bobbing and rocking on the waves, a claw waving.
    for t in range(24):
        rock = (4, 4, 0, -4, -4, 0)[t // 2 % 6]
        bob = 0.5 if t // 3 % 2 else 0.0
        f, head = aboard(bob, rock, eyes="glee", arms=("raised" if t // 3 % 2 else "high", "rest"))
        boat(f, bx, bob, 2 if t % 4 < 2 else 1, tilt=rock)
        waves(f, t + 4)
    # Sail down, a hop back out, and the boat breaks up into the water.
    f, head = aboard(eyes="open"); boat(f, bx, 0.0, 0); waves(f, 28)
    f, head = aboard(eyes="shut", bottom=1.0); boat(f, bx, 0.0); waves(f, 29)
    f, head = frame(lift=1.5, eyes="glee", arms=("up", "up")); boat(f, bx, 0.0, sink=1)
    f, head = frame(lift=0.5, eyes="glee"); boat(f, bx, 0.0, sink=2)
    frame(bottom=1.5, eyes="glee")
    frame(eyes="glee")
    frame()
    return {"fps": 12, "frames": frames}


# MARK: Calling you

BANG_MARK = ["##",
             "##",
             "##",
             "##",
             "..",
             "##"]


def act_calling():
    frames = []

    def pose(mark=0.0, **body):
        f = Frame()
        head = clawd(f, **body)
        if mark is not None:
            f.sprite(BANG_MARK, 3.5, head.top + 1.5 + mark, {"#": SALMON})
        frames.append(f)
        return f, head

    pose(mark=None)
    pose(mark=None, bottom=1.5, eyes="shut")
    pose(mark=0.5, lift=1.0, eyes="wide", arms=("up", "up"))
    hold(frames)
    pose(mark=0.0, eyes="wide")
    lead = len(frames)
    # Waving at you, rocking side to side, the mark bouncing.
    for i in range(12):
        way = 1 if i // 3 % 2 == 0 else -1
        pose(mark=0.5 if i % 3 == 0 else 0.0, tilt=5 * way, arms=("rest", "raised" if way > 0 else "high"),
             bottom=1.5 if i % 6 == 0 else 2.0)
    loop = (lead, len(frames) - 1)
    pose(mark=0.0, arms=("rest", "up"))
    pose(mark=None)
    pose(mark=None)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Reading

# After Claude FM's reading Clawd: big maroon glasses, a frame round each
# eye 3 units square with its corners cut (the outer ones softened a tone
# lighter), a bridge between them and the arms out at the sides; the eyes
# look down through them at a blue book held low at the right.
GLASSES = [".mMMMM......MMMMm.",
           ".M....M....M....M.",
           ".M....MMMMMM....M.",
           "MM....M....M....MM",
           ".M....M....M....M.",
           ".mMMMM......MMMMm."]
# The book open in the claw: its cover facing you, the page edges cream
# along its top and side, the front cover standing up at the right.
BOOK = ["....b",
        "....b",
        "ccccb",
        "cBBBb",
        "BBBBb",
        "BBBBb",
        "BBBBb"]
BOOK_SHUT = ["cccc.",
             "cBBBb",
             "BBBBb",
             "BBBBb",
             "BBBBb"]
# A page turning over, stood up, halfway and laid down to the left.
PAGE_TURN = [[(1.5, 3.0), (1.5, 3.5), (1.5, 4.0)],
             [(1.0, 3.5), (0.5, 4.0), (1.5, 3.0)],
             [(0.0, 3.5), (0.5, 3.5), (1.0, 3.5)]]


def glasses(f, x, y):
    """The maroon glasses with their bottom left at (x, y)."""
    fill(f, sprite_cells(GLASSES, x, y, "M"), MAROON)
    fill(f, sprite_cells(GLASSES, x, y, "m"), MAROON_LIGHT)


def book(f, x, y=1.0, shut=False, page=None):
    """The blue book with its bottom left at (x, y); `page` turns a page."""
    art = BOOK_SHUT if shut else BOOK
    fill(f, sprite_cells(art, x, y, "B"), BLUE)
    fill(f, sprite_cells(art, x, y, "b"), BLUE_DARK)
    fill(f, sprite_cells(art, x, y, "c"), CREAM)
    if page is not None:
        fill(f, {(x + px, y + py - 1.0) for px, py in PAGE_TURN[page]}, CREAM)


def act_reading():
    frames = []

    def pose(specs=0.0, reading=True, turn=0.0, look=(0.5, -0.5), eyes="open", shut=False, page=None, pop=False,
             **body):
        """`specs` lifts the glasses off the eyes (None: none); `turn` (0,
        0.5, 1) turns Clawd toward the book as the official one does: its
        face moves over, its near side goes into shade, the far claw goes
        behind it and the book comes round in front."""
        f = Frame()
        arms = (None if turn else "rest", None if reading else "rest")
        head = clawd(f, arms=arms, eyes=eyes, look=(look[0] + turn, look[1]) if reading else (0.0, 0.0), **body)
        if turn:
            fill(f, rect_cells(0, head.top - 6.0, turn, 6.0), SHADE)
        if specs is not None:
            glasses(f, -0.5 + turn, head.top - 3.0 + specs)
        if reading:
            # The claw behind the book, only its tip showing past the cover.
            bx = 7.0 - turn
            fill(f, rect_cells(bx + 1.0, 2.5, 2.0, 2.0), BODY)
            book(f, bx, shut=shut, page=page)
        if pop:
            for x, y in ((7.0, 4.5), (10.5, 4.0), (6.5, 2.5), (10.5, 1.5)):
                dot(f, x, y, CREAM)
        frames.append(f)
        return f, head

    # On go the glasses, dropped from above with a squash, then the book
    # pops into the claw.
    pose(specs=None, reading=False)
    pose(specs=3.0, reading=False, eyes="up")
    pose(specs=1.5, reading=False, eyes="up")
    pose(specs=0.0, reading=False, bottom=1.5, eyes="shut")
    hold(frames)
    pose(specs=0.0, reading=False, look=(0.0, 0.0))
    pose(pop=True, look=(0.0, 0.0))
    pose()
    lead = len(frames)

    # Reading as Claude FM's Clawd does: still over the page for a second,
    # then turning into the book and back; a page turned on the second go;
    # and a look up at you, a blink, and back down.
    def read(n):
        for _ in range(n):
            pose()

    def lean(page_at=None):
        for k, turn in enumerate((0.5, 0.5, 1.0, 1.0, 1.0, 0.5, 0.5)):
            page = None
            if page_at is not None and 0 <= k - page_at < 3:
                page = k - page_at
            pose(turn=turn, page=page)

    read(12)
    lean()
    read(12)
    lean(page_at=2)
    read(4)
    pose(look=(0.0, 0.0))
    pose(look=(0.0, 0.0))
    pose(look=(0.0, 0.0), eyes="shut")
    pose(look=(0.0, 0.0))
    pose(look=(0.0, 0.0))
    read(4)
    loop = (lead, len(frames) - 1)

    # Done: the book shut and gone, the glasses lifted off.
    pose(shut=True)
    hold(frames)
    pose(pop=True, reading=False, look=(0.0, 0.0))
    pose(reading=False, look=(0.0, 0.0), eyes="content")
    pose(specs=1.5, reading=False, eyes="up")
    pose(specs=3.5, reading=False, eyes="up")
    pose(specs=None, reading=False)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Yawn

NIGHTCAP = [".........######.....",
            ".......##########...",
            ".....############dd.",
            "...##############ddpp",
            ".cccccccccccccccc..pp"]


def nightcap(f, head, lift=0.0):
    """A salmon nightcap flopping over to the right, a cream band and pom-pom."""
    x, y = -0.5, head.top - 0.5 + lift
    for key, color in (("#", SALMON), ("d", SALMON_DARK), ("cp", CREAM)):
        fill(f, turn_cells(sprite_cells(NIGHTCAP, x, y, key), head.tilt, head.pivot), color)


def act_yawn():
    frames = []

    def pose(cap=True, mouth=False, tear=False, zees=0, **body):
        f = Frame()
        head = clawd(f, **body)
        if cap:
            nightcap(f, head)
        if mouth:
            x, y = head.at(4.0, head.top - 3.5)
            f.add(snap(x - 0.5), snap(y - 0.75), 1.0, 1.5, EYE)
        if tear:
            dot(f, snap(head.at(2.5, 0)[0]), head.top - 2.5, CREAM)
        for k in range(zees):
            f.sprite(["###", ".#.", "###"], 9.0 + k * 1.0, head.top + 0.5 + k * 1.5, {"#": CREAM})
        frames.append(f)
        return f, head

    f, head = pose(cap=False)
    for x, y in ((1.0, 9.0), (3.5, 9.5), (6.0, 9.0), (7.5, 8.5)):
        dot(f, x, y, CREAM)
    # Nodding off under the cap...
    for k in range(6):
        pose(eyes="shut", bottom=1.5 if k in (2, 3) else 2.0, tilt=(0, -3, -5, -5, -3, 0)[k], zees=1 if k >= 3 else 0)
    # ...a big stretch and a yawn...
    pose(eyes="shut", height=6.5, arms=("up", "up"))
    for k in range(8):
        pose(eyes="shut", height=7.0, arms=("raised", "raised"), mouth=True, tilt=(0, 2, 3, 3, 2, 0, 0, 0)[k])
    pose(eyes="shut", height=6.5, arms=("high", "high"))
    pose(eyes="shut", bottom=1.5, arms=("low", "low"))
    # ...and blinking awake, a sleepy tear in one eye.
    for k in range(6):
        pose(eyes=("open", "shut") if k % 3 == 0 else "open", tear=k < 4)
    f, head = pose(cap=False)
    for x, y in ((0.5, 8.5), (3.5, 9.5), (6.5, 9.0), (8.5, 8.0)):
        dot(f, x, y, CREAM)
    pose(cap=False)
    return {"fps": 12, "frames": frames}


# MARK: Skateboard

def skateboard(f, x, y, tilt=0.0, pivot=None):
    """A salmon deck, turned up at both ends, on two gray wheels, its bottom
    left at (x, y)."""
    deck = {(x + i * 0.5, y + 0.5) for i in range(1, 19)}
    tails = {(x, y + 1.0), (x + 9.5, y + 1.0), (x + 0.5, y + 0.5), (x + 9.0, y + 0.5)}
    wheels = {(x + dx, y) for dx in (1.0, 1.5, 7.5, 8.0)}
    pivot = pivot or (x + 5, y)
    fill(f, turn_cells(deck - tails, tilt, pivot), SALMON)
    fill(f, turn_cells(tails, tilt, pivot), SALMON_DARK)
    fill(f, turn_cells(wheels, tilt, pivot), GRAY)


def speed_lines(f, t, y0=2.0):
    """Dotted streaks trailing off behind, for speed."""
    for k, y in enumerate((y0, y0 + 2.0, y0 + 4.0)):
        start = -3.0 - ((t + k * 2) % 4) * 0.5
        for i in range(3 - k % 2):
            dot(f, start - i * 1.0, y, CREAM)


def act_skateboard():
    frames = []
    sx = -1.0  # the deck's left end

    def ride(lift=1.0, tilt=-4.0, board_tilt=0.0, push=False, **body):
        """On the board, leaning into the ride; `push` sends a foot down to the ground."""
        f = Frame()
        streaks = body.pop("streaks", None)
        head = clawd(f, side=True, lift=lift, bottom=body.pop("bottom", 1.5), tilt=tilt,
                     arms=(None, body.pop("claw", "rest")), eyes=body.pop("eyes", "glee"), **body)
        if push:
            f.add(-0.5, 0, 1, lift + 0.5, SHADE)
        skateboard(f, sx, lift - 1.0, board_tilt, pivot=(sx + 5, lift - 1.0))
        if streaks is not None:
            speed_lines(f, streaks)
        frames.append(f)
        return f, head

    f = Frame(); clawd(f, side=True, arms=(None, "rest")); skateboard(f, sx + 4.0, 0.0); frames.append(f)
    f = Frame(); clawd(f, side=True, arms=(None, "rest"), bottom=1.5, eyes="shut"); skateboard(f, sx + 2.0, 0.0); frames.append(f)
    f = Frame(); clawd(f, side=True, arms=(None, "up"), lift=1.5, eyes="wide"); skateboard(f, sx, 0.0); frames.append(f)
    ride(bottom=1.0, tilt=0.0)
    lead = len(frames)
    # Rolling along: a push off the ground, then a long glide, crouched low.
    for i in range(16):
        pushing = i < 4
        ride(push=pushing and i % 2 == 0, bottom=1.0 if pushing else 1.5, tilt=-4 if pushing else -7,
             claw="up" if i % 8 < 4 else "high", streaks=None if pushing else i)
    loop = (lead, len(frames) - 1)
    # An ollie: crouch, spring, the board kicked up with it, and down.
    ride(bottom=1.0, tilt=0.0, eyes="shut")
    ride(lift=2.5, bottom=2.0, tilt=5.0, board_tilt=12.0, eyes="wide", claw="raised")
    ride(lift=3.0, bottom=2.0, tilt=3.0, board_tilt=6.0, claw="raised")
    hold(frames)
    ride(lift=2.0, bottom=1.5, tilt=0.0, board_tilt=-4.0, claw="up")
    ride(bottom=1.0, tilt=0.0, eyes="shut")
    # Off the board, which flips up into a claw and is gone.
    f = Frame(); clawd(f, side=True, arms=(None, "up"), lift=1.0, eyes="glee"); skateboard(f, sx, 0.0, 30, (sx + 9, 0)); frames.append(f)
    f = Frame(); clawd(f, side=True, arms=(None, "rest"), bottom=1.5, eyes="glee"); frames.append(f)
    f = Frame(); clawd(f, side=True, arms=(None, "rest"), eyes="glee"); frames.append(f)
    f = Frame(); clawd(f, side=True, arms=(None, "rest")); frames.append(f)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Gaming

# A sofa from the front: its back, drawn behind Clawd, and its arms, cushion
# and base, drawn over it. Clawd lies on it on its belly, facing a TV.
SOFA_BACK = ["..ooooooooooooooooooooooooo..",
             ".ooooooooooooooooooooooooooo.",
             "ooooooooooooooooooooooooooooo",
             "ooooooooooooooooooooooooooooo",
             "ooooooooooooooooooooooooooooo",
             "ddddddddddddddddddddddddddddd",
             "ooooooooooooooooooooooooooooo"]
SOFA_FRONT = [".aa.........................aa.",
              "aaae.......................eaa.",
              "aaae.......................eaaa",
              "aaaecccccccccccccccccccccccaaaa",
              "aaaekkkkkkkkkkkkkkkkkkkkkkkaaaa",
              "fffffffffffffffffffffffffffffff",
              "ggggggggggggggggggggggggggggggg",
              ".l...........................l."]
# The sofa's tones: gray, darker where it's in shadow, a salmon cushion.
SOFA_COLORS = {"o": GRAY, "a": GRAY, "f": GRAY, "d": GRAY_DARK, "e": GRAY_DARK, "g": GRAY_DARK,
               "c": SALMON, "k": SALMON_DARK, "l": INK}
SOFA_X = -7.5
# An old TV on stubby legs, rabbit ears up, its screen 11 by 6 pixels.
TV = ["...a.......a...",
      "....a.....a....",
      ".....a...a.....",
      "......a.a......",
      "hhhhhhhhhhhhhhh",
      "wssssssssssswkw",
      "wssssssssssswww",
      "wssssssssssswkw",
      "wssssssssssswww",
      "wssssssssssswkw",
      "wssssssssssswww",
      "xxxxxxxxxxxxxxx",
      ".xx.........xx."]
# A wooden cabinet in Claude FM's browns: lit along the top, dark along the
# bottom and its legs; gray knobs and rabbit ears.
TV_COLORS = {"w": WOOD, "h": WOOD_LIGHT, "x": WOOD_DARK, "k": GRAY, "a": GRAY}
TV_X = 9.5
# A small gamepad, turned to face you as the TV does, a gray d-pad and four
# buttons, its grips at the bottom.
PAD = [".##########.",
       "##d#####t###",
       "#ddd###l#r##",
       "##d#####b###",
       "####....####"]
PAD_BUTTONS = {"t": AMBER, "l": SALMON, "r": SALMON, "b": AMBER}
# Clawd in the game, legs apart and together as it runs.
MINI = [["###",
         "#.#"],
        ["###",
         ".#."]]


def cells_of(f):
    """The half-unit cells a frame's solid blocks cover."""
    return {(x + i * 0.5, y + j * 0.5) for x, y, w, h, _, _ in f.blocks if w >= 0.5
            for i in range(round(w * 2)) for j in range(round(h * 2))}


def sofa(f, over=set(), poof=False):
    """The sofa, its back behind Clawd and its front over it, save where
    `over` is in front of it; `poof` is it popping in, as an outline of dots."""
    back = sprite_cells(SOFA_BACK, SOFA_X + 0.5, 2.0, "od")
    front = sprite_cells(SOFA_FRONT, SOFA_X, 0.0, "afegckl")
    if poof:
        whole = back | front
        for x, y in sorted(whole):
            edge = any((x + dx, y + dy) not in whole for dx, dy in ((0.5, 0), (-0.5, 0), (0, 0.5), (0, -0.5)))
            if edge and round((x + y) * 2) % 2 == 0:
                dot(f, x, y, CREAM)
        return
    for key in "od":
        fill(f, sprite_cells(SOFA_BACK, SOFA_X + 0.5, 2.0, key), SOFA_COLORS[key], back=True)
    for key in "afegckl":
        fill(f, sprite_cells(SOFA_FRONT, SOFA_X, 0.0, key) - over, SOFA_COLORS[key])


def tv(f, y=0.0, picture=None, poof=False):
    """The TV standing `y` up. `picture` is what's on: None (off), "line"
    or "dot" (switching on or off), or {colour: cells} of the game."""
    cells = sprite_cells(TV, TV_X, y, "whxkas")
    if poof:
        for x, cy in sorted(cells):
            if round((x + cy) * 2) % 3 == 0:
                dot(f, x, cy, CREAM)
        return
    f.sprite(TV, TV_X, y, TV_COLORS)
    screen = sprite_cells(TV, TV_X, y, "s")
    lit = {}
    if picture == "line":
        lit = {CREAM: {(x, cy) for x, cy in screen if cy == y + 2.5}}
    elif picture == "band":
        lit = {CREAM: {(x, cy) for x, cy in screen if y + 2.0 <= cy <= y + 3.0}}
    elif picture == "dot":
        lit = {CREAM: {(TV_X + 3.0, y + 2.5)}}
    elif picture:
        lit = {color: {(x, cy + y) for x, cy in spots} for color, spots in picture.items() if color != "dots"}
    fill(f, screen - set().union(*lit.values()) if lit else screen, INK)
    for color, spots in lit.items():
        fill(f, spots, color)
    if isinstance(picture, dict):
        for x, cy, color in picture.get("dots", ()):
            dot(f, x, cy + y, color)


def game(t, jump=0, prize=None, flash=False):
    """The picture `t` frames into a run: the ground scrolling by in dots, a
    pillar coming, a little Clawd `jump` pixels up, and a `prize` (a coin or
    a star) at its cell."""
    x0, y0 = TV_X + 0.5, 1.0
    pic = {"dots": [(x0 + i * 0.5, y0, GRAY) for i in range(11) if (i + t // 2) % 2 == 0]}
    runner = sprite_cells(MINI[0] if jump else MINI[(t // 2) % 2], x0 + 1.0, y0 + 0.5 + jump * 0.5)
    pic[BODY] = runner
    col = 10 - (t % 24) // 2
    if 0 <= col <= 10:
        pic[SALMON] = {(x0 + col * 0.5, y0 + 0.5), (x0 + col * 0.5, y0 + 1.0)}
    if prize:
        pic[AMBER] = {prize}
    for x, y in ((x0 + 1.5, y0 + 2.5), (x0 + 4.0, y0 + 2.0)):
        if not flash:
            pic["dots"].append((x, y, CREAM))
    if flash:
        pic["dots"] += [(x0 + i * 0.5, y0 + 2.5, CREAM) for i in range(0, 11, 2)]
    return pic


def act_gaming():
    frames = []
    X0, Y0 = -1.0, 2.0            # where Clawd lies: its back end, on the cushion

    def lying(f, height=5.5, kick=0, eyes="open", look=(0.0, -0.5), lift=0.0, press=None, pad=True):
        """Clawd on its belly on the sofa, side on to face the TV, its legs
        up behind it, the gamepad in its claw in front of it on the cushion.
        Returns what's in front of the sofa."""
        top = Y0 + height
        body = rect_cells(X0, Y0, 8, height)
        shade = rect_cells(X0, Y0, 2, height)
        # Legs up behind, from its back end, kicking in turn: the far one in
        # shade, the near one over it.
        far = rect_cells(X0 - 0.5, Y0 + 1.0, 1, 3.0, 50 if kick else 30, (X0 + 0.5, Y0 + 1.0))
        near = rect_cells(X0 + 0.0, Y0 + 1.0, 1, 3.0, 30 if kick else 50, (X0 + 1.0, Y0 + 1.0))
        fill(f, far - near - body, SHADE)
        fill(f, near - body, BODY)
        fill(f, body - shade, BODY)
        fill(f, shade, SHADE)
        for ex in (3.5, 7.5):
            eye(f, X0 + ex - 0.5 + look[0], top - 2.0 + look[1], eyes, X0 + 5)
        over = set()
        if pad:
            px, py = X0 + 2.5, Y0 - 0.5 + lift
            claw = rect_cells(X0 + 7.5, py + 0.5, 1.5, 2)
            cells = sprite_cells(PAD, px, py, "#dtlrb")
            fill(f, cells - sprite_cells(PAD, px, py, "dtlrb") - claw, INK)
            fill(f, sprite_cells(PAD, px, py, "d"), GRAY)
            for key, color in PAD_BUTTONS.items():
                fill(f, sprite_cells(PAD, px, py, key) - claw, CREAM if key == press else color)
            fill(f, claw, BODY)
            over = cells | claw
        return over

    def scene(tv_y=0.0, picture=None, sofa_on=True, sofa_poof=False, tv_poof=False, standing=None, hold=1, **pose):
        """One frame, `hold` frames long: the TV (and what's on), the sofa,
        and Clawd, lying on it or, `standing`, in front of it (a dict for
        clawd())."""
        f = Frame()
        if standing is not None:
            clawd(f, **standing)
            over = cells_of(f)
            if sofa_on or sofa_poof:
                sofa(f, over, poof=sofa_poof)
        else:
            over = lying(f, **pose)
            sofa(f, over)
        if tv_y is not None:
            tv(f, tv_y, picture, poof=tv_poof)
        frames.extend([f] * hold)
        return f

    # The TV drops in, the sofa pops up, Clawd hops on and flops down, and
    # the TV comes on: a line, a band, the game.
    scene(tv_y=None, sofa_on=False, standing={})
    scene(tv_y=7.0, sofa_on=False, standing=dict(eyes="up", look=(0.5, 0.0)))
    scene(tv_y=3.0, sofa_on=False, standing=dict(eyes="up", look=(0.5, 0.0)))
    scene(tv_y=0.0, sofa_on=False, standing=dict(eyes="wide", look=(0.5, 0.0), bottom=1.5), hold=2)
    scene(sofa_on=False, sofa_poof=True, standing=dict(eyes="wide", look=(0.5, 0.0)))
    scene(standing=dict(eyes="glee"), hold=2)
    scene(standing=dict(bottom=1.5, eyes="shut"))
    scene(standing=dict(lift=2.5, height=6.5, side=True, arms=(None, "up"), eyes="wide"))
    scene(height=4.5, eyes="shut", pad=False, hold=2)
    scene(height=5.0, eyes="open", pad=False, kick=1)
    scene(kick=1)
    scene(picture="line")
    scene(picture="band", kick=1)
    lead = len(frames)

    # Three runs of 24 frames: a pillar comes, the little Clawd jumps it (and
    # Clawd lifts the pad with it, kicking); the second grabs a coin in the
    # air (glee); the third a star, the screen flashes and Clawd cheers.
    arc = {8: 1, 9: 2, 10: 3, 11: 3, 12: 3, 13: 2, 14: 1}
    for run in range(3):
        for i in range(24):
            t = run * 24 + i
            jump = arc.get(i, 0)
            prize = None
            if run == 1 and i < 11:
                prize = (TV_X + 0.5 + (10 - i // 2) * 0.5 - 1.0, 1.0 + 2.0)
            if run == 2 and i < 11:
                prize = (TV_X + 0.5 + (10 - i // 2) * 0.5 - 1.0, 1.0 + 2.0)
            picture = game(t, jump, prize, flash=run == 2 and 11 <= i <= 16 and i % 2 == 1)
            eyes, lift, kick = "open", 0.0, (t // 4) % 2
            if 7 <= i <= 9:
                eyes, lift = "wide", 0.5
            if run == 0 and i == 3:
                eyes = "shut"
            if run == 1 and 11 <= i <= 15:
                eyes = "glee"
            if run == 2 and 11 <= i <= 19:
                eyes, lift, kick = "glee", (1.0 if i < 16 else 0.5), (t // 2) % 2
            scene(picture=picture, eyes=eyes, lift=lift, kick=kick, press="t" if i in (7, 8) else "r" if i in (2, 17) else None)
    loop = (lead, len(frames) - 1)

    # The TV goes off, a band, a line, a dot; Clawd hops down, and the sofa
    # and the TV go in a puff.
    scene(picture="band")
    scene(picture="line")
    scene(picture="dot")
    scene(pad=False, eyes="content")
    scene(standing=dict(lift=2.0, height=6.5, eyes="glee"))
    scene(standing=dict(bottom=1.5, eyes="glee"))
    scene(sofa_on=False, sofa_poof=True, tv_poof=True, standing=dict(eyes="glee"))
    scene(tv_y=None, sofa_on=False, standing=dict(eyes="glee"), hold=3)
    scene(tv_y=None, sofa_on=False, standing={})
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Wizard

WIZARD_HAT = ["...........l#.....",
              "..........l#......",
              ".........l##......",
              "........l###......",
              ".......l#####.....",
              "......l#######....",
              ".....l#########...",
              "..lll###########..",
              "##################"]
WIZARD_STARS = [(5.0, 1.5), (3.5, 2.5), (5.5, 3.5)]
PLUS = [".#.",
        "###",
        ".#."]


def wizard_hat(f, head, lift=0.0):
    """A dark pointed hat, its tip bent over, specked with cream stars."""
    x, y = -0.5, head.top + lift
    fill(f, turn_cells(sprite_cells(WIZARD_HAT, x, y, "#"), head.tilt, head.pivot), INK)
    fill(f, turn_cells(sprite_cells(WIZARD_HAT, x, y, "l"), head.tilt, head.pivot), INK_LIGHT)
    for sx, sy in WIZARD_STARS:
        px, py = head.at(x + sx, y + sy)
        dot(f, snap(px), snap(py), CREAM)


def act_wizard():
    frames = []

    def pose(hat=0.0, wand=None, **body):
        """`wand` is where its star is, relative to the head's top right."""
        f = Frame()
        head = clawd(f, **body)
        if hat is not None:
            wizard_hat(f, head, hat)
        if wand is not None:
            tx, ty = head.at(8.0 + wand[0], head.top + wand[1])
            tx, ty = snap(tx), snap(ty)
            # The wand from the claw up to its star.
            cx, cy = head.at(9.0, head.top - 2.0)
            steps = 4
            for k in range(1, steps):
                f.add(snap(cx + (tx - cx) * k / steps), snap(cy + (ty - cy) * k / steps), 0.5, 0.5, GRAY)
            f.sprite(PLUS, tx - 0.5, ty - 0.5, {"#": CREAM})
        frames.append(f)
        return f, head

    pose(hat=None)
    f, head = pose(hat=None)
    for x, y in ((1.0, 9.0), (4.0, 10.0), (7.0, 9.0)):
        dot(f, x, y, CREAM)
    pose(hat=2.0, eyes="up")
    pose(hat=0.0, bottom=1.5, eyes="shut")
    # Wand up, leaning back...
    pose(arms=("rest", "raised"), wand=(1.0, 3.0), tilt=5, eyes="up")
    pose(arms=("rest", "raised"), wand=(0.5, 3.5), tilt=6, eyes="up", height=6.5)
    # ...a swish, trailing dots, and a burst of light.
    f, head = pose(arms=("rest", "up"), wand=(3.5, 0.5), tilt=-5, eyes="wide")
    for k in range(6):
        a = math.radians(100 - k * 15)
        dot(f, snap(9.0 + 3.5 * math.cos(a)), snap(head.top - 1.0 + 3.5 * math.sin(a)), CREAM)
    f, head = pose(arms=("rest", "up"), wand=(3.5, 0.0), tilt=-5, eyes="glee")
    burst = sprite_cells(["..#..", ".###.", "#####", ".###.", "..#.."], 12.0, head.top - 2.0)
    fill(f, burst, CREAM)
    glow(f, burst, 1.5)
    hold(frames)
    # Sparkles drift down all around, a star rising out of them; a bow.
    for t in range(14):
        bow = t >= 9
        f, head = pose(arms=("rest", "rest" if bow else "up"), wand=None if bow else (3.0, 0.5),
                       tilt=-7 if bow else 0, eyes="shut" if bow else "glee", bottom=1.5 if t == 10 else 2.0)
        for k in range(10):
            x = -2.0 + (k * 2.3) % 15
            y = 12.0 - ((t * 0.5 + k * 1.7) % 9)
            if (k + t) % 3:
                dot(f, snap(x), snap(y), CREAM)
        f.sprite(PLUS if t % 2 else ["#"], 4.0 - (0.5 if t % 2 else 0), 10.0 + t * 0.5, {"#": CREAM})
    f, head = pose(hat=0.0)
    f, head = pose(hat=None)
    for x, y in ((1.0, 9.0), (4.0, 10.0), (7.0, 9.0)):
        dot(f, x, y, CREAM)
    pose(hat=None)
    return {"fps": 12, "frames": frames}


# MARK: Guitar

GUITAR_BODY = [".lll.ll",
               "l######",
               ".##cc#.",
               "###cc#.",
               ".####.."]


def guitar(f, head, strum=0.0):
    """A black electric guitar across Clawd's front, a cream pickguard, its
    gray neck running up to the right; turned with Clawd."""
    body = sprite_cells(GUITAR_BODY, 4.5, 2.5, "#")
    lit = sprite_cells(GUITAR_BODY, 4.5, 2.5, "l")
    guard = sprite_cells(GUITAR_BODY, 4.5, 2.5, "c")
    neck = {(8.0 + k * 0.5, 4.5 + k * 0.5) for k in range(7)}
    peg = {(11.5, 8.0), (11.5, 8.5), (11.0, 8.0)}
    fill(f, turn_cells(body, head.tilt, head.pivot), INK)
    fill(f, turn_cells(lit, head.tilt, head.pivot), INK_LIGHT)
    fill(f, turn_cells(guard, head.tilt, head.pivot), CREAM)
    fill(f, turn_cells(neck, head.tilt, head.pivot), GRAY)
    fill(f, turn_cells(peg, head.tilt, head.pivot), INK)
    # The strumming claw over the strings.
    claw = rect_cells(6.0, 3.5 + strum, 1.5, 1.5)
    fill(f, turn_cells(claw, head.tilt, head.pivot), BODY)


def act_guitar():
    frames = []
    notes = [NOTE_ONE, NOTE_TWO]

    def pose(strum=0.0, playing=True, **body):
        f = Frame()
        head = clawd(f, side=True, arms=(None, "rest"), **body)
        if playing:
            guitar(f, head, strum)
        frames.append(f)
        return f, head

    pose(playing=False)
    f, head = pose(playing=False)
    for x, y in ((5.0, 4.0), (8.0, 5.5), (10.5, 7.5)):
        dot(f, x, y, CREAM)
    pose(strum=1.0, tilt=6, eyes="shut", height=6.5)
    pose(strum=1.0, tilt=7, eyes="shut", height=6.5)
    lead = len(frames)
    # Rocking out: a headbang and a strum on every beat, notes and sparks flying.
    for i in range(12):
        down = i % 3 == 0
        f, head = pose(strum=-0.5 if down else 0.5, tilt=-7 if down else 0, bottom=1.5 if down else 2.0,
                       eyes="shut" if down else "glee")
        age = i % 6
        f.sprite(notes[i // 6], 11.0 + age * 0.5, 8.5 + age * 0.5, {"#": CREAM})
        if down:
            for a in (20, 70, 120):
                dot(f, snap(12.5 + 1.5 * math.cos(math.radians(a))), snap(8.5 + 1.5 * math.sin(math.radians(a))), AMBER)
    loop = (lead, len(frames) - 1)
    # The big finish: leaning right back, claw thrown up.
    pose(strum=1.0, tilt=8, height=6.5, eyes="shut")
    pose(strum=1.0, tilt=8, height=6.5, eyes="shut")
    pose(strum=0.0, eyes="glee")
    f, head = pose(playing=False, eyes="glee")
    for x, y in ((5.0, 4.0), (8.0, 5.5), (10.5, 7.5)):
        dot(f, x, y, CREAM)
    pose(playing=False)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Kite

KITE = ["..s..",
        ".scs.",
        "scccs",
        ".scs.",
        ".scs.",
        "..s.."]


def kite(f, x, y, sway=0):
    """The kite with its bottom point at (x, y), its tail fluttering below."""
    f.sprite(KITE, x - 1.0, y, {"s": SALMON, "c": CREAM})
    for k in range(4):
        tx = x + (0.5 if (k + sway) % 2 else 0.0) - 0.5
        f.add(tx, y - 0.5 - k * 0.5, 0.5, 0.5, SALMON if k % 2 else CREAM)


def act_kite():
    frames = []

    def pose(kx, ky, sway=0, **body):
        f = Frame()
        head = clawd(f, side=True, arms=(None, "raised"), eyes="up", **body)
        hx, hy = head.at(9.0, head.top + 1.0)
        # The string sags a little from the claw up to the kite.
        for k in range(1, 12):
            t = k / 12
            x = hx + (kx - hx) * t
            y = hy + (ky - hy) * t - math.sin(math.pi * t) * 0.8
            if k % 2 == 0:
                dot(f, math.floor(x * 2) / 2, math.floor(y * 2) / 2, GRAY)
        kite(f, kx, ky, sway)
        frames.append(f)
        return f, head

    f = Frame(); clawd(f, side=True, arms=(None, "rest")); frames.append(f)
    # Up it goes...
    for kx, ky in ((11.0, 7.0), (12.0, 9.0), (13.0, 10.5), (13.5, 11.5)):
        pose(kx, ky, tilt=4)
    lead = len(frames)
    # ...and flies: drifting and bobbing, a tug on the string now and then.
    drift = [(14.0, 12.0), (14.5, 12.0), (14.5, 12.5), (14.0, 12.5), (13.5, 12.0), (13.5, 11.5)]
    for i in range(24):
        kx, ky = drift[i // 4 % 6]
        tug = i % 12 in (6, 7)
        pose(kx, ky, sway=i // 2, tilt=8 if tug else 3, bottom=1.5 if tug else 2.0)
    loop = (lead, len(frames) - 1)
    # Reeled back in.
    for kx, ky in ((12.5, 10.5), (11.5, 9.0), (10.5, 7.5)):
        pose(kx, ky, tilt=2)
    f = Frame(); clawd(f, side=True, arms=(None, "up"), eyes="glee"); frames.append(f)
    f = Frame(); clawd(f, side=True, arms=(None, "rest")); frames.append(f)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: Sparkler

def act_sparkler():
    frames = []
    import random
    rng = random.Random(3)
    circle = [(1.0, 0.0), (0.5, 1.0), (-0.5, 1.0), (-1.0, 0.0), (-0.5, -1.0), (0.5, -1.0)]

    def pose(tip, sparks=10, trail=(), **body):
        f = Frame()
        head = clawd(f, side=True, arms=(None, "up"), **body)
        cx, cy = head.at(9.0, head.top - 1.0)
        tx, ty = snap(cx + 1.5 + tip[0]), snap(cy + 2.5 + tip[1])
        # The stick from the claw to the burning tip.
        for k in range(1, 4):
            f.add(snap(cx + (tx - cx) * k / 4), snap(cy + (ty - cy) * k / 4), 0.5, 0.5, GRAY)
        f.add(tx, ty, 0.5, 0.5, CREAM)
        for x, y in trail:
            dot(f, x, y, AMBER)
        for n in range(sparks):
            a = rng.uniform(0, 2 * math.pi)
            r = rng.choice((0.5, 1.0, 1.0, 1.5, 2.0))
            x, y = snap(tx + r * math.cos(a)), snap(ty + r * math.sin(a))
            # The brightest few are whole pixels.
            if n < sparks // 4 and r <= 1.0:
                f.add(x, y, 0.5, 0.5, CREAM)
            else:
                dot(f, x, y, rng.choice((CREAM, AMBER, CREAM)))
        frames.append(f)
        return f, head, (tx, ty)

    f = Frame(); clawd(f, side=True, arms=(None, "rest")); frames.append(f)
    pose((0.0, 0.0), sparks=0, eyes="up")
    pose((0.0, 0.0), sparks=4, eyes="wide")
    lead = len(frames)
    # Waving it round and round, crackling, a trail of sparks left behind.
    trail = []
    for i in range(18):
        f, head, tip = pose(circle[i % 6], sparks=9, trail=list(trail), eyes="glee",
                            bottom=1.5 if i % 6 == 0 else 2.0, tilt=(3, 0, -3, -3, 0, 3)[i % 6])
        trail = (trail + [tip])[-3:]
    loop = (lead, len(frames) - 1)
    # Burning down to nothing.
    for sparks in (5, 2, 0):
        pose((0.0, 0.0), sparks=sparks, eyes="open")
    f = Frame(); clawd(f, side=True, arms=(None, "rest"), eyes="glee"); frames.append(f)
    f = Frame(); clawd(f, side=True, arms=(None, "rest")); frames.append(f)
    return {"fps": 12, "frames": frames, "loop": loop}


# MARK: All of them

ACTIONS = {
    "laptop": act_laptop, "headphones": act_headphones, "idea": act_idea, "sunglasses": act_sunglasses, "bubbles": act_bubbles,
    "love": act_love, "dizzy": act_dizzy, "confetti": act_confetti, "thinking": act_thinking,
    "detective": act_detective, "hardhat": act_hardhat, "sailboat": act_sailboat, "calling": act_calling,
    "reading": act_reading, "yawn": act_yawn, "skateboard": act_skateboard, "gaming": act_gaming,
    "wizard": act_wizard, "guitar": act_guitar, "kite": act_kite, "sparkler": act_sparkler,
}


# MARK: Lottie

def rgba(hex_color):
    return [int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)] + [1]


def lottie(name, action):
    frames = action["frames"]
    count = len(frames)
    layers = []
    for index, (color, back) in enumerate(stacking(frames)):
        groups = []
        for t, frame in enumerate(frames):
            rects = [b for b in frame.blocks if b[4:6] == (color, back)]
            if not rects:
                continue
            items = []
            for x, y, w, h in (r[:4] for r in rects):
                x0, x1 = BODY_LEFT + x * 100, BODY_LEFT + (x + w) * 100
                y0, y1 = CANVAS_H - (y + h) * 100, CANVAS_H - y * 100
                items.append({"ty": "sh", "ks": {"a": 0, "k": {
                    "i": [[0, 0]] * 4, "o": [[0, 0]] * 4, "v": [[x0, y0], [x1, y0], [x1, y1], [x0, y1]], "c": True}}})
            keys = [{"t": 0, "s": [100 if t == 0 else 0], "h": 1}]
            if t > 0:
                keys.append({"t": t, "s": [100], "h": 1})
            if t + 1 < count:
                keys.append({"t": t + 1, "s": [0], "h": 1})
            items.append({"ty": "fl", "c": {"a": 0, "k": rgba(color)}, "o": {"a": 1, "k": keys}, "r": 1, "bm": 0})
            items.append({"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]},
                          "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}, "sk": {"a": 0, "k": 0}, "sa": {"a": 0, "k": 0}})
            groups.append({"ty": "gr", "nm": f"frame {t}", "it": items})
        layers.append({"ddd": 0, "ind": index + 1, "ty": 4, "nm": color + (" behind" if back else ""), "sr": 1, "ao": 0, "ip": 0, "op": count,
                       "st": 0, "bm": 0, "shapes": groups,
                       "ks": {"o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0}, "p": {"a": 0, "k": [0, 0, 0]},
                              "a": {"a": 0, "k": [0, 0, 0]}, "s": {"a": 0, "k": [100, 100, 100]}}})
    doc = {"v": "5.7.4", "fr": action["fps"], "ip": 0, "op": count, "w": CANVAS_W, "h": CANVAS_H,
           "nm": f"Clawd-{name}", "ddd": 0, "assets": [], "layers": layers}
    if "loop" in action:
        start, end = action["loop"]
        doc["markers"] = [{"cm": "loop", "tm": start, "dr": end - start + 1}]
    return doc


# MARK: Previews

# What the previews show, in grid units: all the room the pet's window has
# around Clawd at the Code tab's size.
VIEW = (-6, 0, 18, 16)


def render(frame, order, scale, view=VIEW, background=(31, 30, 29)):
    """One frame as an image, `scale` pixels to a unit, drawn layer by layer."""
    from PIL import Image, ImageDraw
    x0, y0, x1, y1 = view
    img = Image.new("RGB", (int((x1 - x0) * scale), int((y1 - y0) * scale)), background)
    draw = ImageDraw.Draw(img)
    for key in reversed(order):
        for x, y, w, h, color, back in frame.blocks:
            if (color, back) != key:
                continue
            draw.rectangle([round((x - x0) * scale), round((y1 - y - h) * scale),
                            round((x + w - x0) * scale) - 1, round((y1 - y) * scale) - 1], fill=color)
    return img


def preview(name, action, scale=12):
    order = stacking(action["frames"])
    return [render(frame, order, scale) for frame in action["frames"]]


def sheet(name, action, scale=13, columns=6):
    """Every distinct picture in the clip, labelled with the frames that show it."""
    from PIL import Image, ImageDraw
    order = stacking(action["frames"])
    runs = []
    for i, frame in enumerate(action["frames"]):
        key = sorted(frame.blocks)
        if runs and runs[-1][0] == key:
            runs[-1][2] = i
        else:
            runs.append([key, i, i, frame])
    cells = [render(frame, order, scale) for _, _, _, frame in runs]
    w, h = cells[0].size
    img = Image.new("RGB", (columns * (w + 4), ((len(cells) + columns - 1) // columns) * (h + 4)), (60, 60, 60))
    draw = ImageDraw.Draw(img)
    loop = action.get("loop")
    for n, (cell, (_, a, b, _)) in enumerate(zip(cells, runs)):
        ox, oy = (n % columns) * (w + 4), (n // columns) * (h + 4)
        img.paste(cell, (ox, oy))
        # The ground and the body's standing box, faintly.
        gy = oy + round(VIEW[3] * scale) - 1
        draw.line([(ox, gy), (ox + w, gy)], fill=(70, 68, 66))
        label = f"{a}" if a == b else f"{a}-{b}"
        if loop and loop[0] <= a <= loop[1]:
            label += " loop"
        draw.text((ox + 4, oy + 3), label, fill=(210, 210, 210))
    return img


def actual(name, action, picks=None, columns=6, zoom=3, view=(-5, 0, 17, 15)):
    """Frames as they land on a Retina screen at the Code tab's size: 2.9
    points a unit, 2 pixels a point, every edge rounded to a whole pixel as
    the pet draws them; then blown up `zoom` times to look at."""
    from PIL import Image, ImageDraw
    frames = action["frames"]
    order = stacking(frames)
    if picks is None:
        picks = [i for i in range(len(frames)) if i == 0 or sorted(frames[i].blocks) != sorted(frames[i - 1].blocks)]
    u = 80 / 27.5 * 2
    x0, y0, x1, y1 = view
    cells = []
    for i in picks:
        img = Image.new("RGB", (round((x1 - x0) * u), round((y1 - y0) * u)), (31, 30, 29))
        draw = ImageDraw.Draw(img)
        for key in reversed(order):
            for x, y, w, h, color, back in frames[i].blocks:
                if (color, back) != key:
                    continue
                left, right = round((x - x0) * u), round((x + w - x0) * u)
                top, bottom = round((y1 - y - h) * u), round((y1 - y) * u)
                if right > left and bottom > top:
                    draw.rectangle([left, top, right - 1, bottom - 1], fill=color)
        cells.append(img.resize((img.width * zoom, img.height * zoom), Image.NEAREST))
    w, h = cells[0].size
    sheet = Image.new("RGB", (min(columns, len(cells)) * (w + 4), ((len(cells) + columns - 1) // columns) * (h + 4)),
                      (60, 60, 60))
    for n, cell in enumerate(cells):
        sheet.paste(cell, ((n % columns) * (w + 4), (n // columns) * (h + 4)))
    return sheet


def check(name, action):
    """Everything solid is on Clawd's half-unit grid; the only finer things
    are the film's dots, a quarter unit square in the middle of a cell."""
    for t, frame in enumerate(action["frames"]):
        for block in frame.blocks:
            x, y, w, h = block[:4]
            if w == h == 0.25:
                ok = all(abs((v - 0.125) * 2 - round((v - 0.125) * 2)) < 1e-9 for v in (x, y))
            else:
                ok = all(abs(v * 2 - round(v * 2)) < 1e-9 for v in (x, y, w, h))
            if not ok:
                sys.exit(f"{name} frame {t}: {block} is off Clawd's grid")


def main():
    os.makedirs(OUT, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    for name, make in ACTIONS.items():
        if only and name not in only:
            continue
        action = make()
        check(name, action)
        with open(os.path.join(OUT, f"{name}.lottie.json"), "w") as f:
            json.dump(lottie(name, action), f, separators=(",", ":"))
        print(f"{name}: {len(action['frames'])} frames at {action['fps']} fps")
        if "--preview" in sys.argv:
            os.makedirs(PREVIEWS, exist_ok=True)
            images = preview(name, action)
            if "loop" in action:
                # The lead-in, three times round the loop, then the outro.
                start, end = action["loop"]
                images = images[:start] + images[start:end + 1] * 3 + images[end + 1:]
            images[0].save(os.path.join(PREVIEWS, f"{name}.gif"), save_all=True, append_images=images[1:],
                           duration=int(1000 / action["fps"]), loop=0)
            sheet(name, action).save(os.path.join(PREVIEWS, f"{name}-sheet.png"))
            actual(name, action).save(os.path.join(PREVIEWS, f"{name}-actual.png"))


if __name__ == "__main__":
    main()
