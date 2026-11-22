"""Makes the Android app's gallery thumbnails (android/app/src/main/assets/thumbs/<id>.webp) and the
picture Android's wallpaper picker shows for the app, from the wallpapers themselves.

    python scripts/make-android-thumbs.py [--exe LiteWallpaper.exe] [--only dragon,snow] [--wide out_dir]

Run it after scripts/convert-for-android.py (it reads that script's wallpapers.json). Needs Pillow.
Each wallpaper is drawn offscreen by "LiteWallpaper.exe --render", like the README previews: shaders
as wide as their picture, then cut to the slice a phone shows (the same sum as ShaderScene.kt), and
particle effects straight onto a phone-shaped canvas, sized like a phone's screen.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ASSETS = os.path.join(ROOT, "android", "app", "src", "main", "assets")
PICKER = os.path.join(ROOT, "android", "app", "src", "main", "res", "drawable-nodpi", "wallpaper_thumb.webp")

THUMB = (288, 512)    # 9:16, a little more than a gallery tile's pixels on a dense phone
DRAW = 2              # drawn at twice that, then scaled down smoothly
PHONE_CSS_WIDTH = 412  # a typical phone's width in particles.js (CSS) pixels
PICKER_SIZE = (432, 768)


def render(exe, source, w, h, css_width=None):
    """One frame of a wallpaper (after a second's run-up), as a PIL image."""
    fd, raw = tempfile.mkstemp(suffix=".bgra")
    os.close(fd)
    try:
        args = [exe, "--render", source, raw, str(w), str(h), "0.05", "20"]
        if css_width:
            args.append(str(css_width))
        code = subprocess.run(args).returncode
        if code != 0:
            raise RuntimeError(f"--render failed ({code})")
        with open(raw, "rb") as f:
            data = f.read(w * h * 4)
        if len(data) != w * h * 4:
            raise RuntimeError("--render wrote no frame")
        return Image.frombuffer("RGBA", (w, h), data, "raw", "BGRA", 0, 1).convert("RGB")
    finally:
        os.remove(raw)


def portrait_copy(path):
    """The shader as the phone app builds it for tall screens: PORTRAIT defined, its portrait
    pictures in place of the wide ones. Written next to it (its includes resolve the same)."""
    import re
    code = open(path, encoding="utf-8").read()
    for wide_key, tall_key in (("texture", "texture_portrait"), ("texture1", "texture1_portrait")):
        m = re.search(r"^// " + tall_key + r":\s*(.+?)\s*$", code, re.M)
        if m:
            code = re.sub(r"^// " + wide_key + r":.*$", "// " + wide_key + ": " + m.group(1), code, count=1, flags=re.M)
    out = os.path.join(os.path.dirname(path), "zz_thumb_portrait.hlsl")
    open(out, "w", encoding="utf-8").write("#define PORTRAIT 1\n" + code)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=os.path.join(ROOT, "LiteWallpaper.exe"))
    ap.add_argument("--only", default="")
    ap.add_argument("--wide", help="also save each shader's whole (uncut) frame here, to check focus points")
    a = ap.parse_args()
    only = {x for x in a.only.split(",") if x}

    catalog = json.load(open(os.path.join(ASSETS, "wallpapers.json"), encoding="utf-8"))
    out_dir = os.path.join(ASSETS, "thumbs")
    os.makedirs(out_dir, exist_ok=True)
    w, h = THUMB[0] * DRAW, THUMB[1] * DRAW
    total = 0
    for wp in catalog:
        if only and wp["id"] not in only:
            continue
        if wp["kind"] == "particles":
            img = render(a.exe, os.path.join(ROOT, wp["file"]), w, h, PHONE_CSS_WIDTH * DRAW)
        else:
            v = wp.get("portrait") or wp  # a phone held upright shows the version for tall screens
            aspect, focus = v.get("aspect", 16 / 9), v.get("focus", 0.5)
            wide = max(w, round(h * aspect / 2) * 2)
            src = os.path.join(ROOT, "shaders", wp["id"] + ".hlsl")
            if "portrait" in wp:
                src = portrait_copy(src)
            try:
                full = render(a.exe, src, wide, h)
            finally:
                if "portrait" in wp:
                    os.remove(src)
            if a.wide:
                os.makedirs(a.wide, exist_ok=True)
                full.save(os.path.join(a.wide, wp["id"] + ".jpg"), quality=88)
            left = round(min(max(focus * wide - w / 2, 0), wide - w))
            img = full.crop((left, 0, left + w, h))
        if wp["id"] == "dragon":
            os.makedirs(os.path.dirname(PICKER), exist_ok=True)
            img.resize(PICKER_SIZE, Image.LANCZOS).save(PICKER, quality=86, method=6)
        path = os.path.join(out_dir, wp["id"] + ".webp")
        img.resize(THUMB, Image.LANCZOS).save(path, quality=82, method=6)
        size = os.path.getsize(path)
        total += size
        print(f"{wp['id']:<20} {size / 1024:6.1f} KB")
    print(f"{'total':<20} {total / 1024:6.1f} KB")


if __name__ == "__main__":
    sys.exit(main())
