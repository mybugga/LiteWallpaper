"""Lifts the hands off a clock picture so a wallpaper can show the real time with them:

    python scripts/make-clock-hands.py [amethyst_clock dragon_clock] [--check out_dir]

From shaders/assets/<name>.jpg it writes
    <name>_plate.jpg       the picture without its hands (the dial filled in where they were)
    <name>_hands.png       an atlas, one square tile per hand (premultiplied colour and alpha),
                           each tile centred on the hub with the hand where it lay in the picture
    ../<name>_hands.hlsli  the shader's numbers: hub, cap, tile layout, each hand's angle
The hands are found from rough positions (below), refined from the picture itself. The dial under
them is filled smoothly from round about, and its fine detail (texture, tick marks, hour markers) is
taken from the dial itself turned by whole hours, since the markings repeat every 30 degrees.
"""
import math, os, sys
import numpy as np
import cv2
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ASSETS = os.path.join(ROOT, "shaders", "assets")

# Positions in the 2560x1440 pictures: the hub (centre of the cap, fitted to its edge), the cap's
# radius, the dial's radius (inside the rim), and per hand, drawn bottom to top: its tip (read off at
# 6x zoom), how far its tail reaches past the hub, its widest half-width, where along it that is
# (0-1), and the half-width of its tail (a counterweight ring).
CLOCKS = {
    "amethyst_clock": dict(hub=(1472.9, 697.8), cap=13.5, dial=318, hands=[
        ("hour", (1392, 514), 30, 10, 0.45, 7),
        ("minute", (1725, 604), 28, 8, 0.4, 6),
        ("second", (1263, 886), 62, 2.6, 0.5, 14),
    ]),
    # The fireflies in the dragon picture fly about in the wallpaper: lifted off here too.
    "dragon_clock": dict(hub=(1477.5, 677.7), cap=24.0, dial=385, fireflies=[(1171, 126), (1881, 202), (1954, 785), (951, 1065)], hands=[
        ("hour", (1305, 560), 18, 14, 0.62, 6),
        ("minute", (1706, 498), 18, 11, 0.55, 6),
        ("second", (1263, 916), 68, 3.0, 0.5, 8),
    ]),
}


def half_width(s, L, tail, half, widest, tail_half):
    """How wide the hand may be at distance s along it from the hub (negative: its tail)."""
    body = np.where(s <= widest * L, half, half + (max(1.8, half * 0.22) - half) * (s - widest * L) / max((1 - widest) * L, 1))
    body = np.where(s > L + 3, 0.0, body)
    return np.where(s < 0, np.where(s >= -tail, tail_half, 0.0), body)


def load(name):
    return np.asarray(Image.open(os.path.join(ASSETS, name + ".jpg")).convert("RGB"), dtype=np.float32) / 255.0


def seg_dist(xx, yy, a, b):
    """Distance from each pixel to segment a-b, and how far along it (0 at a, 1 at b)."""
    ax, ay = a; bx, by = b
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    t = np.clip(((xx - ax) * dx + (yy - ay) * dy) / L2, 0, 1)
    px, py = ax + t * dx, ay + t * dy
    return np.hypot(xx - px, yy - py), t


def angle_of(hub, p):
    """Clock angle (0 at twelve, clockwise) of point p seen from the hub (picture y points down)."""
    return math.atan2(p[0] - hub[0], -(p[1] - hub[1]))


def process(name, check_dir=None):
    c = CLOCKS[name]
    img = load(name)
    h, w, _ = img.shape
    hx, hy = c["hub"]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    rr = np.hypot(xx - hx, yy - hy)

    # The dial without hands, roughly: a wide median (the hands are narrow).
    u8 = (img * 255).astype(np.uint8)
    bg = cv2.medianBlur(u8, 41).astype(np.float32) / 255.0
    diff = np.abs(img - bg).max(axis=-1)

    hands = []
    for i, (hname, tip, tail, half, widest, tail_half) in enumerate(c["hands"]):
        th = angle_of((hx, hy), tip)
        L = math.hypot(tip[0] - hx, tip[1] - hy)
        L += 1.0
        for _ in range(1):
            ux, uy = math.sin(th), -math.cos(th)
            s = (xx - hx) * ux + (yy - hy) * uy        # along the hand
            n = np.abs((xx - hx) * uy - (yy - hy) * ux)  # across it
            allowed = half_width(s, L, tail, half, widest, tail_half)
            strip = (n <= allowed + 1.5) & (allowed > 0) & (rr > c["cap"] - 3)
            core = strip & (diff > 0.1)
            # The hand: the parts of what stands out in its outline that join up with its spine
            # (so specks of dial texture and the ends of tick marks don't come along).
            core8 = cv2.morphologyEx(core.astype(np.uint8), cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
            count, labels = cv2.connectedComponents(core8, connectivity=8)
            spine = core8.astype(bool) & (n <= 2.5) & (s > -tail) & (s < L * 0.85)
            keep = np.isin(labels, np.unique(labels[spine])) & (labels > 0)
        # A hand's outline is symmetric about its axis even where one side is shaded darker than
        # the other: fill each side from the other's mirror image.
        mx = (hx + (xx - hx) - 2 * ((xx - hx) * uy - (yy - hy) * ux) * uy).astype(np.float32)
        my = (hy + (yy - hy) + 2 * ((xx - hx) * uy - (yy - hy) * ux) * ux).astype(np.float32)
        mirrored = cv2.remap(keep.astype(np.float32), mx, my, cv2.INTER_LINEAR) > 0.5
        solid = cv2.erode((keep | mirrored).astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
        support = cv2.dilate((keep | mirrored).astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)
        alpha = np.maximum(np.clip((diff - 0.05) / 0.08, 0, 1) * support, solid.astype(np.float32)) * (n <= allowed + 2)
        alpha[rr <= c["cap"] - 1.5] = 0  # the cap stays in the plate, on top of everything
        hands.append(dict(name=hname, angle=th, length=L, tail=tail, alpha=alpha.astype(np.float32)))
    # Where hands overlap in the picture, the upper one (later in the list) owns the pixels.
    owner = np.full((h, w), -1, np.int32)
    for i, hd in enumerate(hands):
        owner[hd["alpha"] > 0.15] = i
    for i, hd in enumerate(hands):
        hd["alpha"] = hd["alpha"] * ((owner == i) | (owner == -1) | (hd["alpha"] <= 0.15))

    # ---- the plate: fill where the hands were (and their soft edges) ----
    hole = np.zeros((h, w), np.uint8)
    for hd in hands:
        hole |= (hd["alpha"] > 0.02).astype(np.uint8)
    hole = cv2.dilate(hole, np.ones((5, 5), np.uint8))
    hole[rr <= c["cap"] + 0.5] = 0
    # The cap is no source for the dial round it: hide it behind the dial's own colour while filling.
    src = u8.copy()
    ring = (rr > c["cap"] + 6) & (rr < c["cap"] + 30) & (hole == 0)
    src[rr <= c["cap"] + 2.5] = np.median(u8[ring], axis=0).astype(np.uint8)
    smooth = cv2.inpaint(src, hole, 9, cv2.INPAINT_TELEA).astype(np.float32) / 255.0
    lowf = lambda im: cv2.GaussianBlur(im, (0, 0), 7)
    detail_src = img - lowf(img)
    # Fine detail from the dial turned by whole hours, wherever that's clear of hands.
    detail = np.zeros_like(img)
    got = np.zeros((h, w), np.float32)
    hole_f = hole.astype(np.float32)
    for k in (1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6):
        ang = k * math.pi / 6
        M = cv2.getRotationMatrix2D((hx, hy), -math.degrees(ang), 1.0)
        rot_detail = cv2.warpAffine(detail_src, M, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
        rot_hole = cv2.warpAffine(hole_f, M, (w, h), flags=cv2.INTER_LINEAR, borderValue=1.0)
        use = (got < 0.5) & (rot_hole < 0.02) & (hole > 0)
        detail[use] = rot_detail[use]
        got[use] = 1
    plate = img.copy()
    filled = lowf(smooth) + detail
    soft = cv2.GaussianBlur(hole_f, (0, 0), 1.5)
    plate = plate * (1 - soft[..., None]) + filled * soft[..., None]
    plate = np.clip(plate, 0, 1)
    flies = c.get("fireflies", [])
    if flies:  # they sit on the dark background, so filling round about leaves dark
        fm = np.zeros((h, w), np.uint8)
        for (fx, fy) in flies:
            cv2.circle(fm, (fx, fy), 26, 1, -1)
        plate = cv2.inpaint((plate * 255 + 0.5).astype(np.uint8), fm, 7, cv2.INPAINT_TELEA).astype(np.float32) / 255.0
    Image.fromarray((plate * 255 + 0.5).astype(np.uint8)).save(os.path.join(ASSETS, name + "_plate.jpg"), quality=94)

    # ---- the hands atlas: one tile per hand, centred on the hub ----
    reach = int(math.ceil(max(max(hd["length"], hd["tail"]) for hd in hands) + 12))
    tile = 2 * reach
    atlas = np.zeros((tile, tile * len(hands), 4), np.float32)
    bgfill = smooth  # the dial under each hand, to un-mix its anti-aliased edges
    # Tile pixel (u, v) shows picture point (hub - reach + u, hub - reach + v): the hub is the exact
    # middle of the tile, to the sub-pixel.
    M = np.float32([[1, 0, -(hx - reach)], [0, 1, -(hy - reach)]])
    for i, hd in enumerate(hands):
        a = hd["alpha"]
        prem = np.clip(img - (1 - a[..., None]) * bgfill, 0, 1) * (a[..., None] > 0)
        sub_p = cv2.warpAffine(prem, M, (tile, tile), flags=cv2.INTER_LINEAR)
        sub_a = cv2.warpAffine(a, M, (tile, tile), flags=cv2.INTER_LINEAR)
        atlas[:, i * tile:(i + 1) * tile, :3] = sub_p
        atlas[:, i * tile:(i + 1) * tile, 3] = sub_a
    # Stored straight (un-premultiplied) in the PNG: both apps premultiply when they load it.
    a4 = atlas[..., 3:4]
    straight = np.where(a4 > 1e-3, atlas[..., :3] / np.maximum(a4, 1e-3), 0)
    rgba = np.concatenate([np.clip(straight, 0, 1), a4], axis=-1)
    Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(ASSETS, name + "_hands.png"), optimize=True)

    # ---- the numbers for the shader ----
    # Shaders measure pixels from the picture's edge (a pixel's middle is at +0.5), NumPy from the
    # middle of the first pixel: hence the 0.5s.
    lines = [f"// Made by scripts/make-clock-hands.py from assets/{name}.jpg: don't edit by hand.",
             f"static const float2 kHub = float2({hx + 0.5:.1f}, {hy + 0.5:.1f});   // picture pixels",
             f"static const float kCapR = {c['cap']:.1f};                 // the cap over the hands",
             f"static const float kDialR = {c['dial']:.1f};",
             f"static const float kTile = {tile:.1f};                  // hands atlas: square tiles, hub in the middle",
             f"static const float kHandCount = {len(hands)}.0;"]
    for i, hd in enumerate(hands):
        lines.append(f"static const float kAngle{hd['name'].capitalize()} = {hd['angle']:.5f};  // radians, as in the picture (tile {i})")
    if flies:
        lines.append(f"static const float2 kFireflies[{len(flies)}] = {{ " + ", ".join(f"float2({fx + 0.5:.1f}, {fy + 0.5:.1f})" for fx, fy in flies) + " };")
    open(os.path.join(ROOT, "shaders", name + "_hands.hlsli"), "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print(name, "tile", tile, "hands", [(hd["name"], round(math.degrees(hd["angle"]), 1), round(hd["length"])) for hd in hands])

    if check_dir:
        os.makedirs(check_dir, exist_ok=True)
        box = (hx - c["dial"] - 20, hy - c["dial"] - 20, hx + c["dial"] + 20, hy + c["dial"] + 20)
        Image.fromarray((plate * 255).astype(np.uint8)).crop(box).save(os.path.join(check_dir, name + "_plate_check.png"))
        over = img.copy()
        cols = [(1, 0, 0), (0, 1, 0), (0, 0.6, 1)]
        for i, hd in enumerate(hands):
            over = over * (1 - 0.6 * hd["alpha"][..., None]) + np.array(cols[i]) * 0.6 * hd["alpha"][..., None]
        Image.fromarray((np.clip(over, 0, 1) * 255).astype(np.uint8)).crop(box).save(os.path.join(check_dir, name + "_hands_check.png"))
        Image.fromarray((rgba * 255).astype(np.uint8), "RGBA").save(os.path.join(check_dir, name + "_atlas_check.png"))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = sys.argv[sys.argv.index("--check") + 1] if "--check" in sys.argv else None
    if check in args: args.remove(check)
    for n in (args or list(CLOCKS)):
        process(n, check)
