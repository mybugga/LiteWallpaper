"""Makes the helper textures ("_fx.png") the picture wallpapers animate with, from the pictures
themselves. Run after changing one of these pictures:

    python scripts/make-wallpaper-masks.py [northern_lights betta ...]

northern_lights[_portrait]_fx.png
    R = sky (1 above the mountain ridge, where the aurora may move), soft at the ridge
    G, B = the ridge line's height, smoothed, as a 16-bit fraction of the picture's height
           (G low byte, B high byte): the aurora sways more the higher it is above it, and the
           snow just below it catches the aurora's light
betta[_portrait]_fx.png
    R = how far out along a fin (0 at the body, 1 at the tips), for the fins' waves
    G, B = the direction away from the body (0.5 + 0.5 * x, y), the way the waves travel
moon[_portrait]_fx.png, ring_moon_fx.png
    the picture blurred: the light on the moon, which stays put while its craters turn
"""
import os, sys
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ASSETS = os.path.join(ROOT, "shaders", "assets")


def load(name):
    return np.asarray(Image.open(os.path.join(ASSETS, name + ".jpg")).convert("RGB"), dtype=np.float32) / 255.0


def save(name, channels):
    rgb = np.clip(np.stack(channels, axis=-1) * 255.0 + 0.5, 0, 255).astype(np.uint8)
    Image.fromarray(rgb, "RGB").save(os.path.join(ASSETS, name + "_fx.png"), optimize=True)
    print("wrote", name + "_fx.png", rgb.shape[1], "x", rgb.shape[0])


def smooth1d(v, radius):
    k = np.exp(-0.5 * (np.arange(-3 * radius, 3 * radius + 1) / radius) ** 2)
    k /= k.sum()
    pad = np.pad(v, 3 * radius, mode="edge")
    return np.convolve(pad, k, mode="valid")


def blur(a, radius):
    im = Image.fromarray(np.clip(a * 255, 0, 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(radius))
    return np.asarray(im, dtype=np.float32) / 255.0


def northern_lights(name, shore_guess, pale_core):
    img = load(name)
    h, w, _ = img.shape
    r, g, b = img[..., 0], img[..., 1], img[..., 2]
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    # Each column is scanned up from the shore, through the mountains, to where the sky starts: a
    # run of smooth dark sky or of saturated aurora green. Shadowed rock is dark but full of detail,
    # and snow (even lit green) is pale, so neither stops the scan; the aurora's rays higher up
    # never come into it.
    import cv2
    hi = np.max(img, axis=-1)
    sat = (hi - np.min(img, axis=-1)) / np.maximum(hi, 1e-4)
    lap = np.abs(cv2.Laplacian(cv2.GaussianBlur(luma, (0, 0), 1.2), cv2.CV_32F, ksize=3))
    tex = cv2.GaussianBlur(lap, (0, 0), 3)
    # The aurora: green well above red and saturated. Where its bright core is pale (pale_core),
    # pale green that's smooth or bright counts too (its streaks have sharp edges); that's off
    # where the snow itself is pale green.
    green = (g > r * 1.25) & (g > b * 1.05) & (sat > 0.45)
    core = (g > r * 1.1) & (g > b * 1.05) & ((tex < 0.02) | (luma > 0.45)) if pale_core else np.zeros_like(green)
    aurora = green | core
    skyish = (((tex < 0.004) & (luma < 0.06)) | aurora).astype(np.uint8)
    skyish[shore_guess - 6:, :] = 0
    # The sky is what's joined to the top of the picture: shadowed faces walled in by snow aren't.
    flood = skyish.copy()
    mask = np.zeros((h + 2, w + 2), np.uint8)
    for x in range(0, w, 7):
        if flood[0, x] == 1:
            cv2.floodFill(flood, mask, (x, 0), 2, flags=4)
    sky_px = flood == 2
    ridge = np.empty(w)
    for x in range(w):
        col = ~sky_px[:shore_guess, x]
        ridge[x] = np.argmax(col) if col.any() else shore_guess
    # Very pale aurora can wall the fill off, leaving narrow spikes with vertical sides; real peaks
    # slope. Bridge each sudden rise that's followed closely by a sudden fall.
    x = 1
    while x < w:
        if ridge[x] < ridge[x - 1] - 25:
            for x2 in range(x + 1, min(w, x + 140)):
                if ridge[x2] > ridge[x2 - 1] + 25 and abs(ridge[x2] - ridge[x - 1]) < 60:
                    ridge[x:x2] = np.linspace(ridge[x - 1], ridge[x2], x2 - x + 1)[:-1]
                    x = x2
                    break
        x += 1
    # Ignore single specks: a running median over neighbours, then smooth gently.
    ridge = np.array([np.median(ridge[max(0, x - 10):x + 11]) for x in range(w)])
    ridge = smooth1d(ridge, 3)
    ys = np.arange(h)[:, None].astype(np.float32)
    sky = np.clip((ridge[None, :] - 4.0 - ys) / 14.0, 0.0, 1.0)  # fades out over 14 px above the ridge
    # The ridge line smoothed (the aurora sways more the higher it is above it, and must sway the
    # same in neighbouring columns), in 16 bits: G low byte, B high byte. Filtering the two bytes
    # separately still interpolates the value, as it's linear in both.
    soft = smooth1d(ridge, 60)
    v = np.round(np.clip(soft / h, 0, 1) * 65535.0)
    hi_b, lo_b = np.floor(v / 256.0), v % 256.0
    save(name, [sky, np.ones((h, 1)) * (lo_b[None, :] / 255.0), np.ones((h, 1)) * (hi_b[None, :] / 255.0)])


# The fish's head and body, traced by hand (picture pixels): their dark lower scales are too close
# to the fins' colours to tell apart by colour alone.
BETTA_BODY = {
    "betta": [(1084, 650), (1120, 600), (1200, 570), (1300, 536), (1400, 504), (1520, 480), (1680, 472),
              (1820, 484), (1916, 516), (1930, 600), (1920, 670), (1840, 704), (1720, 720), (1580, 724),
              (1440, 724), (1380, 736), (1320, 764), (1220, 770), (1140, 744), (1096, 700)],
    "betta_portrait": [(112, 1222), (150, 1205), (210, 1212), (285, 1245), (360, 1290), (450, 1350),
                       (540, 1425), (630, 1515), (705, 1590), (765, 1645), (790, 1668), (775, 1718),
                       (700, 1728), (610, 1708), (520, 1668), (440, 1622), (380, 1578), (330, 1532),
                       (290, 1492), (240, 1442), (190, 1392), (150, 1332), (125, 1280)],
}


def betta(name):
    img = load(name)
    h, w, _ = img.shape
    r, g, b = img[..., 0], img[..., 1], img[..., 2]
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    fish = luma > 0.035
    red = (r > g * 1.6) & (r > b * 1.25) & fish
    import cv2
    body8 = np.zeros((h, w), np.uint8)
    cv2.fillPoly(body8, [np.array(BETTA_BODY[name], np.int32)], 1)
    dist = cv2.distanceTransform(1 - body8, cv2.DIST_L2, 5).astype(np.float32)
    reach = float(np.percentile(dist[red], 99)) if red.any() else 1.0
    out = np.clip(dist / reach, 0.0, 1.0)
    # Direction away from the body: the smoothed distance field's gradient.
    sm = cv2.GaussianBlur(dist, (0, 0), 24)
    gy, gx = np.gradient(sm)
    norm = np.sqrt(gx * gx + gy * gy) + 1e-6
    save(name, [out, 0.5 + 0.5 * gx / norm, 0.5 + 0.5 * gy / norm])
    print("  fin reach", round(reach), "px; body", int(body8.sum()), "px")


def moon(name, radius):
    """The light on the moon: the picture blurred (by 2% of the moon's radius). The shader turns the
    craters (the picture divided by this) and keeps the light where it is, sunlit edge included."""
    im = Image.open(os.path.join(ASSETS, name + ".jpg")).convert("RGB")
    base = im.filter(ImageFilter.GaussianBlur(radius * 0.02))
    base.save(os.path.join(ASSETS, name + "_fx.png"), optimize=True)
    print("wrote", name + "_fx.png", base.size[0], "x", base.size[1])


if __name__ == "__main__":
    want = set(sys.argv[1:])
    if not want or "moon" in want:
        moon("moon", 955)
        moon("moon_portrait", 1534)
    if not want or "ring_moon" in want:
        moon("ring_moon", 500)  # the light on the rock band, blurred by 10 px
    if not want or "northern_lights" in want:
        northern_lights("northern_lights", 1300, pale_core=True)
        northern_lights("northern_lights_portrait", 2192, pale_core=False)
    if not want or "betta" in want:
        betta("betta")
        betta("betta_portrait")
