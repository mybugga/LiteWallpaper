"""Prepares the wallpapers for the Android app (android/).

  python scripts/convert-for-android.py

Every shader in shaders/ is turned into an OpenGL ES 3.0 fragment shader: it is wrapped the way the
Windows app wraps it (header from src/sources.cpp), compiled from HLSL to SPIR-V by glslang, and
written out as GLSL ES by SPIRV-Cross. So a shader is written once and runs on both.

Writes, under android/app/src/main/assets/:
  shaders/<name>.frag       the converted shaders
  wallpapers.json           every wallpaper: name, description, kind, textures, picture shape, and
                            the point a tall phone screen centres on
  particles/assets/<gif>.frames/   GIF images split into frames (plus delays.json)

Needs glslang (glslangValidator or glslang) and spirv-cross, found through the GLSLANG and
SPIRV_CROSS environment variables or on PATH, and Pillow.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHADERS = os.path.join(ROOT, "shaders")
PARTICLES = os.path.join(ROOT, "particles")
ASSETS = os.path.join(ROOT, "android", "app", "src", "main", "assets")


def tool(env, *names):
    path = os.environ.get(env)
    if path and os.path.exists(path):
        return path
    for n in names:
        found = shutil.which(n)
        if found:
            return found
    sys.exit(f"{names[0]} not found: put it on PATH or set {env}")


GLSLANG = tool("GLSLANG", "glslangValidator", "glslang")
SPIRV_CROSS = tool("SPIRV_CROSS", "spirv-cross")

# The Windows app's wrapper, so shaders see exactly the same names on both.
_src = open(os.path.join(ROOT, "src", "sources.cpp"), encoding="utf-8").read()
HEADER = re.search(r'kShaderHeader\[\] = R"\((.*?)\)";', _src, re.S).group(1)
ADJUST = re.search(r"(float3 _Adjust\(float3 c\) \{.*?\n\})", _src, re.S).group(1)
RAINBOW = re.search(r"(float3 _Rainbow\(float3 c, float2 fragCoord\) \{.*?\n\})", _src, re.S).group(1)
# OpenGL's fragment coordinates already start bottom-left, like Shadertoy. _view.x shifts this
# screen across a wider picture (a tall phone screen shows a slice of a wide wallpaper).
FOOTER = (
    "\ncbuffer View : register(b1) { float4 _view; };\n"
    + ADJUST
    + "\n" + RAINBOW
    + """
float4 PSMain(float4 pos : SV_Position) : SV_Target {
    float2 fragCoord = float2(pos.x + _view.x, pos.y);
    return float4(_Adjust(_Rainbow(saturate(mainImage(fragCoord).rgb), fragCoord)), 1.0);
}
"""
)


def option(code, name):
    m = re.search(r"^// " + re.escape(name) + r":[ \t]*(.+?)[ \t]*$", code, re.M)
    return m.group(1) if m else None


def pretty(name):
    s = name.replace("_", " ").replace("-", " ")
    return s[:1].upper() + s[1:]


def description(code):
    """As the gallery shows it: a "// description:" line, else the comment at the top of the file
    without its "Name:" prefix, cut to whole sentences of about four lines."""
    d = option(code, "description")
    if d is None:
        lines = []
        for line in code.splitlines():
            if not line.startswith("//"):
                break
            line = line[2:].strip()
            if not line or re.match(r"(texture1?|scale|focus|Available):", line):
                break
            lines.append(line)
        d = " ".join(lines)
        m = re.match(r"([^:]{1,31}): ", d)
        if m:
            d = d[m.end():]
    d = re.sub(r" \(see [^)]*\)", "", d).strip()
    if len(d) > 230:
        cut = [m.end() for m in re.finditer(r"\. ", d) if m.end() <= 231]
        d = d[: cut[-1]].strip() if cut else d[:227] + "..."
    return d[:1].upper() + d[1:]


def focus(image_path):
    """Where the picture's subject is, across it (0-1): the brightness-weighted middle, since the
    pictures are subjects on black."""
    im = Image.open(image_path).convert("L")
    im.thumbnail((256, 256))
    w, h = im.size
    px = im.load()
    total = mid = 0.0
    for y in range(h):
        for x in range(w):
            v = (px[x, y] / 255.0) ** 2
            total += v
            mid += v * (x + 0.5) / w
    return round(mid / total, 3) if total > 0 else 0.5


def convert(name, code, work):
    wrapped = os.path.join(work, name + ".hlsl")
    with open(wrapped, "w", encoding="utf-8") as f:
        f.write(HEADER + "\n" + code + "\n" + FOOTER)
    spv = os.path.join(work, name + ".spv")
    frag = os.path.join(work, name + ".frag")
    r = subprocess.run([GLSLANG, "-D", "-V", "--auto-map-bindings", "--auto-map-locations", "-S", "frag", "-e", "PSMain",
                        "-I" + SHADERS, "-o", spv, wrapped], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stdout + r.stderr)
    r = subprocess.run([SPIRV_CROSS, spv, "--es", "--version", "300", "--glsl-emit-ubo-as-plain-uniforms",
                        "--remove-unused-variables", "--output", frag], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stdout + r.stderr)
    glsl = open(frag, encoding="utf-8").read()
    # Stable names for what the app sets: the uniform structs and the textures.
    for struct, var in (("Globals", "G"), ("View", "V")):
        m = re.search(r"uniform " + struct + r" (\w+);", glsl)
        if m:
            glsl = re.sub(r"\b" + m.group(1) + r"\b", var, glsl)
    glsl = re.sub(r"SPIRV_Cross_Combined(iChannel[01])iSampler", r"\1", glsl)
    # GetDimensions becomes textureSize on an extra "dummy" sampler that nothing would bind (so it
    # would measure texture unit 0); measure the real one instead.
    glsl = re.sub(r"uniform highp sampler2D SPIRV_Cross_Combined(iChannel[01])SPIRV_Cross_DummySampler;\n", "", glsl)
    glsl = re.sub(r"SPIRV_Cross_Combined(iChannel[01])SPIRV_Cross_DummySampler", r"\1", glsl)
    if "SPIRV_Cross" in glsl:
        raise RuntimeError("unexpected SPIRV-Cross name left: " + re.search(r"SPIRV_Cross\w*", glsl).group(0))
    # Check the result compiles as GLSL ES, as a phone will compile it.
    with open(frag, "w", encoding="utf-8") as f:
        f.write(glsl)
    r = subprocess.run([GLSLANG, "-S", "frag", frag], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError("GLSL ES check failed:\n" + r.stdout + r.stderr)
    return glsl


def split_gif(path, rel):
    """GIFs used by the particle effects, as frames the app can show one after another."""
    out = os.path.join(ASSETS, rel + ".frames")
    os.makedirs(out, exist_ok=True)
    im = Image.open(path)
    canvas = Image.new("RGBA", im.size, (0, 0, 0, 0))
    delays = []
    for i in range(getattr(im, "n_frames", 1)):
        im.seek(i)
        frame = im.convert("RGBA")
        canvas = Image.alpha_composite(canvas, frame) if im.disposal_method != 2 else frame
        canvas.save(os.path.join(out, f"{i}.png"))
        d = im.info.get("duration", 100)
        delays.append(0.1 if d < 20 else d / 1000.0)  # browsers treat 0-10 ms as 100 ms
    with open(os.path.join(out, "delays.json"), "w") as f:
        json.dump(delays, f)


def main():
    out_shaders = os.path.join(ASSETS, "shaders")
    shutil.rmtree(out_shaders, ignore_errors=True)
    os.makedirs(out_shaders)
    entries, failed = [], []
    with tempfile.TemporaryDirectory() as work:
        for file in sorted(os.listdir(SHADERS)):
            if not file.endswith(".hlsl"):
                continue
            name = file[:-5]
            code = open(os.path.join(SHADERS, file), encoding="utf-8-sig").read()
            try:
                glsl = convert(name, code, work)
            except RuntimeError as e:
                failed.append((name, str(e)))
                continue
            with open(os.path.join(out_shaders, name + ".frag"), "w", encoding="utf-8", newline="\n") as f:
                f.write(glsl)
            textures = [("shaders/" + option(code, k).replace("\\", "/")) for k in ("texture", "texture1") if option(code, k)]
            entry = {"id": name, "name": pretty(name), "kind": "shader", "file": "shaders/" + name + ".frag",
                     "textures": textures, "description": description(code)}
            if textures:
                first = os.path.join(ROOT, textures[0])
                w, h = Image.open(first).size
                entry["aspect"] = round(w / h, 4)
                entry["focus"] = float(option(code, "focus") or focus(first))
            else:
                entry["aspect"] = round(16 / 9, 4)
                entry["focus"] = float(option(code, "focus") or 0.5)
            if option(code, "scale"):
                entry["scale"] = float(option(code, "scale"))
            entries.append(entry)
            print(f"{name:22s} {len(glsl.splitlines()):5d} lines  focus {entry['focus']}")

    for file in sorted(os.listdir(PARTICLES)):
        if not file.endswith(".json"):
            continue
        name = file[:-5]
        cfg = json.load(open(os.path.join(PARTICLES, file), encoding="utf-8-sig"))
        for src in (cfg.get("particles", {}).get("shape", {}).get("image", {}).get("src", ""),
                    cfg.get("config_demo", {}).get("background_image", "")):
            if src.lower().endswith(".gif"):
                split_gif(os.path.join(PARTICLES, src), "particles/" + src)
        entries.append({"id": name, "name": pretty(name), "kind": "particles", "file": "particles/" + file,
                        "description": "A particles.js effect, simulated natively. Touch the screen to play with it."})
        print(f"{name:22s} particles")

    with open(os.path.join(ASSETS, "wallpapers.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(entries, f, indent=1)
    if failed:
        for name, err in failed:
            print(f"\n{name} FAILED:\n{err[-2000:]}")
        sys.exit(1)
    print(f"\n{len(entries)} wallpapers")


if __name__ == "__main__":
    main()
