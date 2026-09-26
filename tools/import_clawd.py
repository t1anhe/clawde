#!/usr/bin/env python3
"""Imports Clawd's animations into the pet's block format.

Every animation is a Lottie file drawn by tools/design_actions.py into
assets/actions/: pixel art with one layer per colour, each frame a group of
rectangles whose fill is switched on only on its own frame. This turns every
frame into [x, y, w, h, colour] blocks on Clawd's grid (1 unit = 100 Lottie
units; x from the standing body's left edge, y up from the ground) and writes
Resources/clawd-animations.json for the build to bundle.

    tools/import_clawd.py            convert everything in assets/actions/
"""
import glob
import json
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ACTIONS = os.path.join(ROOT, "assets", "actions")
OUT = os.path.join(ROOT, "Resources", "clawd-animations.json")
# Where the standing body's left edge sits on every Clawd canvas.
BODY_LEFT = 936


def fill_opacity(fill, frame):
    prop = fill["o"]
    if not prop.get("a"):
        return prop["k"]
    value = prop["k"][0]["s"]
    for key in prop["k"]:
        if key["t"] <= frame:
            value = key.get("s", value)
    return value[0] if isinstance(value, list) else value


def snap(value):
    """To the eighth-unit grid: Clawd's pixels are half a unit and the dots
    Clawd's actions draw a quarter unit square, in the middle of a pixel."""
    return round(value * 8) / 8


def main():
    animations = {}
    for path in sorted(glob.glob(os.path.join(ACTIONS, "*.lottie.json"))):
        animations[os.path.basename(path).split(".")[0]] = convert(path)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(animations, f, separators=(",", ":"))
    for name, animation in animations.items():
        print(f"{name}: {len(animation['frames'])} frames at {animation['fps']} fps"
              + (f", looping {animation['loop']}" if "loop" in animation else ""))
    print(f"wrote {os.path.normpath(OUT)}")


def hex_color(rgba):
    return "#" + "".join(f"{round(c * 255):02X}" for c in rgba[:3])


def convert(path):
    """One Lottie file as {fps, frames, loop?}: its frames are ip..op-1."""
    with open(path) as f:
        lottie = json.load(f)
    ground = lottie["h"]
    frames = []
    for frame in range(lottie["ip"], lottie["op"]):
        blocks = []
        # Lottie lists the top layer first; draw from the bottom up.
        for layer in reversed(lottie["layers"]):
            for group in layer["shapes"]:
                fill = next(item for item in group["it"] if item["ty"] == "fl")
                if fill_opacity(fill, frame) < 50:
                    continue
                color = hex_color(fill["c"]["k"])
                for item in group["it"]:
                    if item["ty"] != "sh":
                        continue
                    xs = [p[0] for p in item["ks"]["k"]["v"]]
                    ys = [p[1] for p in item["ks"]["k"]["v"]]
                    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
                    blocks.append([snap((x0 - BODY_LEFT) / 100), snap((ground - y1) / 100),
                                   snap((x1 - x0) / 100), snap((y1 - y0) / 100), color])
        frames.append(blocks)
    animation = {"fps": lottie["fr"], "frames": frames}
    markers = lottie.get("markers", [])
    loop = next((m for m in markers if m.get("cm") == "loop"), None)
    if loop:
        animation["loop"] = [loop["tm"], loop["tm"] + loop["dr"] - 1]
    # The frame a clip touches something the pet draws itself (a note pinned up or pulled down).
    touch = next((m for m in markers if m.get("cm") == "touch"), None)
    if touch:
        animation["touch"] = touch["tm"]
    return animation


if __name__ == "__main__":
    main()
