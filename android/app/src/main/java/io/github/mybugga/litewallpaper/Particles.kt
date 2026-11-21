package io.github.mybugga.litewallpaper

import android.content.Context
import android.opengl.GLES30
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

// Native port of particles.js by Vincent Garreau (MIT license), https://github.com/VincentGarreau/particles.js,
// following the Windows app's port (src/particles.cpp) line for line. Reads particles.js JSON configs
// unchanged. A finger stands in for the mouse: touching and holding is hovering, a tap is a click.

private const val MAX_PARTICLES = 6000
private const val PI = Math.PI.toFloat()

private class Rgb(val r: Float = 1f, val g: Float = 1f, val b: Float = 1f)

private fun parseHex(text: String?, fallback: Rgb): Rgb {
    var s = (text ?: return fallback).removePrefix("#")
    if (s.length == 3) s = "${s[0]}${s[0]}${s[1]}${s[1]}${s[2]}${s[2]}"
    if (s.length != 6) return fallback
    val v = s.toLongOrNull(16) ?: return fallback
    return Rgb(((v shr 16) and 255) / 255f, ((v shr 8) and 255) / 255f, (v and 255) / 255f)
}

private fun hslToRgb(h0: Float, s0: Float, l0: Float): Rgb {
    val h = (((h0 % 360f) + 360f) % 360f) / 360f
    val s = (s0 / 100f).coerceIn(0f, 1f)
    val l = (l0 / 100f).coerceIn(0f, 1f)
    if (s == 0f) return Rgb(l, l, l)
    fun hue(p: Float, q: Float, t0: Float): Float {
        var t = t0
        if (t < 0) t += 1f
        if (t > 1) t -= 1f
        return when {
            t < 1f / 6 -> p + (q - p) * 6 * t
            t < 0.5f -> q
            t < 2f / 3 -> p + (q - p) * (2f / 3 - t) * 6
            else -> p
        }
    }
    val q = if (l < 0.5f) l * (1 + s) else l + s - l * s
    val p = 2 * l - q
    return Rgb(hue(p, q, h + 1f / 3), hue(p, q, h), hue(p, q, h - 1f / 3))
}

private enum class Shape { Circle, Edge, Triangle, Polygon, Star, Image }

private fun shapeOf(s: String?) = when (s) {
    "circle" -> Shape.Circle
    "edge" -> Shape.Edge
    "triangle" -> Shape.Triangle
    "polygon" -> Shape.Polygon
    "star" -> Shape.Star
    "image" -> Shape.Image
    else -> null
}

// Reading JSON the forgiving way particles.js does: anything missing takes the library's default.
private fun JSONObject?.o(key: String): JSONObject? = this?.optJSONObject(key)
private fun JSONObject?.num(key: String, def: Float): Float = when (val v = this?.opt(key)) {
    is Number -> v.toFloat()
    is Boolean -> if (v) 1f else 0f
    else -> def
}
private fun JSONObject?.flag(key: String, def: Boolean): Boolean = when (val v = this?.opt(key)) {
    is Boolean -> v
    is Number -> v.toDouble() != 0.0
    else -> def
}
private fun JSONObject?.str(key: String, def: String): String = (this?.opt(key) as? String) ?: def
private fun modes(v: Any?): List<String> = when (v) {
    is String -> listOf(v)
    is JSONArray -> (0 until v.length()).mapNotNull { v.opt(it) as? String }
    else -> emptyList()
}

/** The particles.js config, with the library's own defaults for anything left out. */
private data class Settings(
    var number: Int = 400, var density: Boolean = true, var densityArea: Float = 800f,
    var color: Any? = "#fff",
    var shapes: List<Shape> = listOf(Shape.Circle),
    var strokeWidth: Float = 0f, var strokeColor: Rgb = Rgb(1f, 0f, 0f), var sides: Float = 5f,
    var imageSrc: String? = null, var imageRatio: Float = 1f,
    var opacity: Float = 1f, var opacitySpeed: Float = 2f, var opacityMin: Float = 0f,
    var opacityRandom: Boolean = false, var opacityAnim: Boolean = false, var opacitySync: Boolean = false,
    var size: Float = 20f, var sizeSpeed: Float = 20f, var sizeMin: Float = 0f,
    var sizeRandom: Boolean = false, var sizeAnim: Boolean = false, var sizeSync: Boolean = false,
    var lines: Boolean = true, var lineDistance: Float = 100f, var lineOpacity: Float = 1f, var lineWidth: Float = 1f,
    var lineColor: Rgb = Rgb(),
    var move: Boolean = true, var moveRandom: Boolean = false, var straight: Boolean = false,
    var outBounce: Boolean = false, var bounce: Boolean = false,
    var speed: Float = 2f, var baseVx: Float = 0f, var baseVy: Float = 0f,
    var attract: Boolean = false, var rotateX: Float = 3000f, var rotateY: Float = 3000f,
    var hoverOn: Boolean = true, var clickOn: Boolean = true,
    var hover: List<String> = listOf("grab"), var click: List<String> = listOf("push"),
    var grabDistance: Float = 100f, var grabOpacity: Float = 1f,
    var bubbleDistance: Float = 200f, var bubbleSize: Float = 80f, var bubbleDuration: Float = 0.4f, var bubbleOpacity: Float = Float.NaN,
    var repulseDistance: Float = 200f, var repulseDuration: Float = 0.4f,
    var pushNb: Int = 4, var removeNb: Int = 2, var retina: Boolean = false,
    var bgColor: Rgb = Rgb(0f, 0f, 0f), var bgImage: String? = null,
    var bgSize: String = "cover", var bgPosition: String = "50% 50%", var bgRepeat: Boolean = false,
) {
    fun load(root: JSONObject, dir: String) {
        val p = root.o("particles")
        number = p.o("number").num("value", number.toFloat()).toInt()
        density = p.o("number").o("density").flag("enable", density)
        densityArea = p.o("number").o("density").num("value_area", densityArea)
        color = p.o("color")?.opt("value") ?: "#fff"

        val sh = p.o("shape")
        val types = when (val t = sh?.opt("type")) {
            is String -> listOfNotNull(shapeOf(t))
            is JSONArray -> (0 until t.length()).mapNotNull { shapeOf(t.opt(it) as? String) }
            else -> emptyList()
        }
        if (types.isNotEmpty()) shapes = types
        strokeWidth = sh.o("stroke").num("width", strokeWidth)
        strokeColor = parseHex(sh.o("stroke").str("color", "#ff0000"), strokeColor)
        sides = max(3f, sh.o("polygon").num("nb_sides", sides))
        imageSrc = asset(sh.o("image").str("src", ""), dir)
        val iw = sh.o("image").num("width", 100f)
        val ih = sh.o("image").num("height", 100f)
        imageRatio = if (iw > 0 && ih > 0) iw / ih else 1f

        val op = p.o("opacity")
        opacity = op.num("value", opacity)
        opacityRandom = op.flag("random", opacityRandom)
        opacityAnim = op.o("anim").flag("enable", opacityAnim)
        opacitySpeed = op.o("anim").num("speed", opacitySpeed)
        opacityMin = op.o("anim").num("opacity_min", opacityMin)
        opacitySync = op.o("anim").flag("sync", opacitySync)

        val sz = p.o("size")
        size = sz.num("value", size)
        sizeRandom = sz.flag("random", sizeRandom)
        sizeAnim = sz.o("anim").flag("enable", sizeAnim)
        sizeSpeed = sz.o("anim").num("speed", sizeSpeed)
        sizeMin = sz.o("anim").num("size_min", sizeMin)
        sizeSync = sz.o("anim").flag("sync", sizeSync)

        val ll = p.o("line_linked")
        lines = ll.flag("enable", lines)
        lineDistance = ll.num("distance", lineDistance)
        lineColor = parseHex(ll.str("color", "#fff"), lineColor)
        lineOpacity = ll.num("opacity", lineOpacity)
        lineWidth = ll.num("width", lineWidth)

        val mv = p.o("move")
        move = mv.flag("enable", move)
        speed = mv.num("speed", speed)
        // Same table as particles.js, including its lopsided bottom-left.
        when (mv.str("direction", "none")) {
            "top" -> { baseVx = 0f; baseVy = -1f }
            "top-right" -> { baseVx = 0.5f; baseVy = -0.5f }
            "right" -> { baseVx = 1f; baseVy = 0f }
            "bottom-right" -> { baseVx = 0.5f; baseVy = 0.5f }
            "bottom" -> { baseVx = 0f; baseVy = 1f }
            "bottom-left" -> { baseVx = -0.5f; baseVy = 1f }
            "left" -> { baseVx = -1f; baseVy = 0f }
            "top-left" -> { baseVx = -0.5f; baseVy = -0.5f }
        }
        moveRandom = mv.flag("random", moveRandom)
        straight = mv.flag("straight", straight)
        outBounce = mv.str("out_mode", "out") == "bounce"
        bounce = mv.flag("bounce", bounce)
        attract = mv.o("attract").flag("enable", attract)
        rotateX = mv.o("attract").num("rotateX", rotateX)
        rotateY = mv.o("attract").num("rotateY", rotateY)

        val ev = root.o("interactivity").o("events")
        hoverOn = ev.o("onhover").flag("enable", hoverOn)
        ev.o("onhover")?.opt("mode")?.let { hover = modes(it) }
        clickOn = ev.o("onclick").flag("enable", clickOn)
        ev.o("onclick")?.opt("mode")?.let { click = modes(it) }
        val md = root.o("interactivity").o("modes")
        grabDistance = md.o("grab").num("distance", grabDistance)
        grabOpacity = md.o("grab").o("line_linked").num("opacity", grabOpacity)
        bubbleDistance = md.o("bubble").num("distance", bubbleDistance)
        bubbleSize = md.o("bubble").num("size", bubbleSize)
        bubbleDuration = md.o("bubble").num("duration", bubbleDuration)
        bubbleOpacity = md.o("bubble").num("opacity", Float.NaN)
        repulseDistance = md.o("repulse").num("distance", repulseDistance)
        repulseDuration = md.o("repulse").num("duration", repulseDuration)
        pushNb = md.o("push").num("particles_nb", pushNb.toFloat()).toInt()
        removeNb = md.o("remove").num("particles_nb", removeNb.toFloat()).toInt()
        retina = root.flag("retina_detect", retina)

        // The particles.js demo page keeps the page background here.
        val bg = root.o("config_demo")
        bgColor = parseHex(bg.str("background_color", "#000000"), bgColor)
        bgImage = asset(bg.str("background_image", ""), dir)
        bgSize = bg.str("background_size", bgSize)
        bgPosition = bg.str("background_position", bgPosition)
        bgRepeat = bg.str("background_repeat", "no-repeat") == "repeat"
    }

    /** Image paths in a config are relative to it; web URLs can't be used offline. */
    private fun asset(src: String, dir: String): String? =
        if (src.isEmpty() || src.startsWith("http://") || src.startsWith("https://") || src.startsWith("data:")) null else "$dir/$src"
}

private class Particle {
    var x = 0f; var y = 0f; var vx = 0f; var vy = 0f; var vxi = 0f; var vyi = 0f
    var radius = 0f; var opacity = 1f; var vs = 0f; var vo = 0f
    var radiusBubble = -1f; var opacityBubble = -1f  // < 0 = not set
    var sizeUp = false; var opacityUp = false
    var color = Rgb()
    var shape = Shape.Circle
}

private class Sim(val bw: Int, val bh: Int, val s: Settings, val drawScale: Float, val pxratio: Float, val retinaOn: Boolean) {
    val w = bw / drawScale  // canvas size in simulation (CSS) pixels
    val h = bh / drawScale
    val ps = ArrayList<Particle>()
    var lines = FloatArray(9 * 256)
    var lineCount = 0

    var mouseIn = false
    var mx = 0f; var my = 0f; var clickX = 0f; var clickY = 0f
    var clickTime = 0.0; var repulseUntil = 0.0
    var bubbleClicking = false; var bubbleDurationEnd = false; var repulseClicking = false

    fun addLine(x0: Float, y0: Float, x1: Float, y1: Float, c: Rgb, a: Float, width: Float) {
        if ((lineCount + 1) * 9 > lines.size) lines = lines.copyOf(lines.size * 2)
        val i = lineCount++ * 9
        lines[i] = x0; lines[i + 1] = y0; lines[i + 2] = x1; lines[i + 3] = y1
        lines[i + 4] = c.r; lines[i + 5] = c.g; lines[i + 6] = c.b; lines[i + 7] = a; lines[i + 8] = width
    }
}

class ParticleScene(private val context: Context, private val wallpaper: Wallpaper) : Scene {
    private val cfg = Settings()
    private val prefs = Prefs(context)
    private val rainbow = FloatArray(4)
    private val bgRgb = FloatArray(3)
    private val bg: Picture?
    private val image: Picture?
    private var sim: Sim? = null
    private var now = 0.0

    private var touchX = 0f
    private var touchY = 0f
    private var touchHeld = false
    private var touchDown = false

    private val partProgram = Gl.program(PART_VS, PART_FS)
    private val lineProgram = Gl.program(LINE_VS, LINE_FS)
    private val bgProgram = Gl.program(Gl.FULLSCREEN_VS, BG_FS)
    private val partVbo: Int
    private val lineVbo: Int
    private val partVao: Int
    private val lineVao: Int
    private var partData: FloatBuffer = buffer(20 * 256)
    private var lineData: FloatBuffer = buffer(9 * 256)

    init {
        val root = JSONObject(context.assets.open(wallpaper.file).bufferedReader().use { it.readText() })
        cfg.load(root, wallpaper.file.substringBeforeLast('/'))
        bg = cfg.bgImage?.let { runCatching { Gl.picture(context, it, 2048, cfg.bgRepeat) }.getOrNull() }
        image = if (Shape.Image in cfg.shapes) cfg.imageSrc?.let { runCatching { Gl.picture(context, it, 512) }.getOrNull() } else null

        val ids = IntArray(2)
        GLES30.glGenBuffers(2, ids, 0)
        partVbo = ids[0]
        lineVbo = ids[1]
        GLES30.glGenVertexArrays(2, ids, 0)
        partVao = ids[0]
        lineVao = ids[1]
        GLES30.glBindVertexArray(partVao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, partVbo)
        attribs(80, intArrayOf(2, 2, 4, 4, 4, 4))
        GLES30.glBindVertexArray(lineVao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, lineVbo)
        attribs(36, intArrayOf(4, 4, 1))
        GLES30.glBindVertexArray(0)
    }

    private fun attribs(stride: Int, sizes: IntArray) {
        var offset = 0
        sizes.forEachIndexed { i, n ->
            GLES30.glEnableVertexAttribArray(i)
            GLES30.glVertexAttribPointer(i, n, GLES30.GL_FLOAT, false, stride, offset)
            GLES30.glVertexAttribDivisor(i, 1)
            offset += n * 4
        }
    }

    override fun touch(x: Float, y: Float, down: Boolean, held: Boolean) {
        touchX = x
        touchY = y
        touchHeld = held
        if (down) touchDown = true
    }

    override fun draw(frame: Frame) {
        now += frame.dt
        var s = sim
        if (s == null || s.bw != frame.width || s.bh != frame.height) {
            s = newSim(frame.width, frame.height, frame.pixelRatio)
            sim = s
        }
        s.mouseIn = touchHeld && cfg.hoverOn
        s.mx = touchX / s.drawScale
        s.my = touchY / s.drawScale
        if (touchDown) {
            touchDown = false
            s.mx = touchX / s.drawScale
            s.my = touchY / s.drawScale
            if (cfg.clickOn) click(s)
        }
        step(s, frame.dt.coerceIn(0f, 0.1f))
        render(s, frame)
    }

    // ---------------------------------------------------------------- simulation

    /** A simulation for this canvas size: particles.js sizes are CSS pixels, a phone's are dense. */
    private fun newSim(bw: Int, bh: Int, pixelRatio: Float): Sim {
        val ratio = max(pixelRatio, 0.25f)
        val retinaOn = cfg.retina && ratio > 1
        val st = cfg.copy()
        // retina_detect: simulate in device pixels with sizes scaled up, exactly like the library.
        // Otherwise simulate in CSS pixels and scale the drawing, the way a browser would.
        if (retinaOn) {
            st.size *= ratio; st.sizeSpeed *= ratio; st.speed *= ratio; st.lineDistance *= ratio; st.grabDistance *= ratio
            st.bubbleDistance *= ratio; st.lineWidth *= ratio; st.bubbleSize *= ratio; st.repulseDistance *= ratio
        }
        val sim = Sim(bw, bh, st, if (retinaOn) 1f else ratio, ratio, retinaOn)
        repeat(min(st.number, MAX_PARTICLES)) { sim.ps.add(newParticle(sim, false, 0f, 0f)) }
        if (st.density) {
            var area = sim.w * sim.h / 1000
            if (retinaOn) area /= ratio * 2
            val wanted = area * st.number / max(st.densityArea, 1f)
            val missing = sim.ps.size - wanted
            if (missing < 0) push(sim, ceil(-missing).toInt(), false)
            else repeat(min(sim.ps.size, missing.toInt())) { sim.ps.removeAt(0) }
        }
        return sim
    }

    private fun rand() = Random.nextFloat()

    private fun newParticle(sim: Sim, atPos: Boolean, px: Float, py: Float): Particle {
        val s = sim.s
        val p = Particle()
        p.radius = (if (s.sizeRandom) rand() else 1f) * s.size
        if (s.sizeAnim) {
            p.vs = s.sizeSpeed / 100
            if (!s.sizeSync) p.vs *= rand()
        }
        p.x = if (atPos) px else rand() * sim.w
        p.y = if (atPos) py else rand() * sim.h
        if (p.x > sim.w - p.radius * 2) p.x -= p.radius else if (p.x < p.radius * 2) p.x += p.radius
        if (p.y > sim.h - p.radius * 2) p.y -= p.radius else if (p.y < p.radius * 2) p.y += p.radius

        if (s.bounce) {  // avoid starting on top of another particle
            for (tries in 0 until 50) {
                val overlap = sim.ps.any { o -> sqrt((p.x - o.x).pow(2) + (p.y - o.y).pow(2)) <= p.radius + o.radius }
                if (!overlap) break
                p.x = rand() * sim.w
                p.y = rand() * sim.h
            }
        }

        p.color = when (val c = s.color) {
            is JSONArray -> if (c.length() > 0) parseHex(c.optString(min(c.length() - 1, (rand() * c.length()).toInt()), "#fff"), Rgb()) else Rgb()
            is JSONObject -> when {
                c.has("r") -> Rgb(c.num("r", 255f) / 255, c.num("g", 255f) / 255, c.num("b", 255f) / 255)
                c.has("h") -> hslToRgb(c.num("h", 0f), c.num("s", 0f), c.num("l", 100f))
                else -> Rgb()
            }
            "random" -> Rgb(floor(rand() * 256) / 255, floor(rand() * 256) / 255, floor(rand() * 256) / 255)
            is String -> parseHex(c, Rgb())
            else -> Rgb()
        }

        p.opacity = (if (s.opacityRandom) rand() else 1f) * s.opacity
        if (s.opacityAnim) {
            p.vo = s.opacitySpeed / 100
            if (!s.opacitySync) p.vo *= rand()
        }

        if (s.straight) {
            p.vx = s.baseVx
            p.vy = s.baseVy
            if (s.moveRandom) {
                p.vx *= rand()
                p.vy *= rand()
            }
        } else {
            p.vx = s.baseVx + rand() - 0.5f
            p.vy = s.baseVy + rand() - 0.5f
        }
        p.vxi = p.vx
        p.vyi = p.vy
        p.shape = s.shapes[min(s.shapes.size - 1, (rand() * s.shapes.size).toInt())]
        return p
    }

    private fun push(sim: Sim, count: Int, atMouse: Boolean) {
        for (i in 0 until count) {
            if (sim.ps.size >= MAX_PARTICLES) break
            sim.ps.add(newParticle(sim, atMouse, sim.mx, sim.my))
        }
    }

    private fun click(sim: Sim) {
        val s = sim.s
        sim.clickX = sim.mx
        sim.clickY = sim.my
        sim.clickTime = now
        for (mode in s.click) when (mode) {
            "push" -> if (s.move || s.pushNb == 1) push(sim, s.pushNb, true) else if (s.pushNb > 1) push(sim, s.pushNb, false)
            "remove" -> repeat(min(sim.ps.size, max(0, s.removeNb))) { sim.ps.removeAt(0) }
            "bubble" -> sim.bubbleClicking = true
            "repulse" -> {
                sim.repulseClicking = true
                sim.repulseUntil = now + s.repulseDuration
            }
        }
    }

    private fun step(sim: Sim, dt: Float) {
        val s = sim.s
        val k = dt * 60  // particles.js frames elapsed
        val grab = s.hoverOn && "grab" in s.hover
        val bubbleHover = s.hoverOn && "bubble" in s.hover
        val bubbleClick = !bubbleHover && s.clickOn && "bubble" in s.click
        val repulseHover = s.hoverOn && "repulse" in s.hover
        val repulseClick = !repulseHover && s.clickOn && "repulse" in s.click
        if (sim.repulseClicking && now >= sim.repulseUntil) sim.repulseClicking = false

        val timeSpent = (now - sim.clickTime).toFloat()
        if (bubbleClick && sim.bubbleClicking) {
            if (timeSpent > s.bubbleDuration) sim.bubbleDurationEnd = true
            if (timeSpent > s.bubbleDuration * 2) {
                sim.bubbleClicking = false
                sim.bubbleDurationEnd = false
            }
        }

        sim.lineCount = 0
        for (p in sim.ps) {
            if (s.move) {
                val ms = s.speed / 2
                p.x += p.vx * ms * k
                p.y += p.vy * ms * k
            }
            if (s.opacityAnim) {
                if (p.opacityUp) {
                    if (p.opacity >= s.opacity) p.opacityUp = false
                    p.opacity += p.vo * k
                } else {
                    if (p.opacity <= s.opacityMin) p.opacityUp = true
                    p.opacity -= p.vo * k
                }
                p.opacity = max(p.opacity, 0f)
            }
            if (s.sizeAnim) {
                if (p.sizeUp) {
                    if (p.radius >= s.size) p.sizeUp = false
                    p.radius += p.vs * k
                } else {
                    if (p.radius <= s.sizeMin) p.sizeUp = true
                    p.radius -= p.vs * k
                }
                p.radius = max(p.radius, 0f)
            }

            // Leaving the canvas: wrap to the opposite edge at a random spot.
            val r = p.radius
            val left = if (s.outBounce) r else -r
            val right = if (s.outBounce) sim.w else sim.w + r
            val top = if (s.outBounce) r else -r
            val bottom = if (s.outBounce) sim.h else sim.h + r
            if (p.x - r > sim.w) { p.x = left; p.y = rand() * sim.h } else if (p.x + r < 0) { p.x = right; p.y = rand() * sim.h }
            if (p.y - r > sim.h) { p.y = top; p.x = rand() * sim.w } else if (p.y + r < 0) { p.y = bottom; p.x = rand() * sim.w }
            if (s.outBounce) {
                if (p.x + r > sim.w) p.vx = -abs(p.vx) else if (p.x - r < 0) p.vx = abs(p.vx)
                if (p.y + r > sim.h) p.vy = -abs(p.vy) else if (p.y - r < 0) p.vy = abs(p.vy)
            }

            if (grab && sim.mouseIn) {
                val d = sqrt((p.x - sim.mx).pow(2) + (p.y - sim.my).pow(2))
                if (d <= s.grabDistance) {
                    val op = s.grabOpacity - d * s.grabOpacity / s.grabDistance
                    if (op > 0) sim.addLine(p.x, p.y, sim.mx, sim.my, s.lineColor, op, s.lineWidth)
                }
            }
            if (bubbleHover) bubbleHover(sim, p) else if (bubbleClick && sim.bubbleClicking) bubbleClick(sim, p, timeSpent)
            if (repulseHover) repulseHover(sim, p, k) else if (repulseClick) repulseClick(sim, p)
        }
        if (s.lines || s.attract) pairs(sim, k)
    }

    private fun bubbleHover(sim: Sim, p: Particle) {
        val s = sim.s
        val d = sqrt((p.x - sim.mx).pow(2) + (p.y - sim.my).pow(2))
        if (!sim.mouseIn || d > s.bubbleDistance) {
            p.opacityBubble = p.opacity
            p.radiusBubble = p.radius
            return
        }
        val ratio = 1 - d / s.bubbleDistance
        if (ratio < 0) return
        if (s.bubbleSize != s.size) {
            if (s.bubbleSize > s.size) {
                val size = p.radius + s.bubbleSize * ratio
                if (size >= 0) p.radiusBubble = size
            } else {
                val size = p.radius - (p.radius - s.bubbleSize) * ratio
                p.radiusBubble = if (size > 0) size else 0f
            }
        }
        if (!s.bubbleOpacity.isNaN() && s.bubbleOpacity != s.opacity) {
            if (s.bubbleOpacity > s.opacity) {
                val op = s.bubbleOpacity * ratio
                if (op > p.opacity && op <= s.bubbleOpacity) p.opacityBubble = op
            } else {
                val op = p.opacity - (s.opacity - s.bubbleOpacity) * ratio
                if (op < p.opacity && op >= s.bubbleOpacity) p.opacityBubble = op
            }
        }
    }

    private fun bubbleClick(sim: Sim, p: Particle, timeSpent: Float) {
        val s = sim.s
        val d = sqrt((p.x - sim.clickX).pow(2) + (p.y - sim.clickY).pow(2))
        fun process(bubbleParam: Float, particlesParam: Float, bubbleValue: Float, value: Float): Float {
            if (bubbleParam == particlesParam || bubbleParam.isNaN()) return bubbleValue
            var out = bubbleValue
            val eased = value - timeSpent * (value - bubbleParam) / s.bubbleDuration
            if (!sim.bubbleDurationEnd) {
                if (d <= s.bubbleDistance) {
                    val current = if (out >= 0) out else value
                    if (current != bubbleParam) out = eased
                } else {
                    out = -1f
                }
            } else if (out >= 0) {
                out = bubbleParam + (bubbleParam - eased)
            }
            if (out < 0 && out != -1f) out = 0f
            return out
        }
        p.radiusBubble = process(s.bubbleSize, s.size, p.radiusBubble, p.radius)
        p.opacityBubble = process(s.bubbleOpacity, s.opacity, p.opacityBubble, p.opacity)
    }

    private fun repulseHover(sim: Sim, p: Particle, k: Float) {
        if (!sim.mouseIn) return
        val s = sim.s
        val dx = p.x - sim.mx
        val dy = p.y - sim.my
        val d = sqrt(dx * dx + dy * dy)
        if (d < 1e-3f) return
        val r = s.repulseDistance
        val factor = ((1 - (d / r) * (d / r)) * 100).coerceIn(0f, 50f) * min(k, 2f)
        val nx = p.x + dx / d * factor
        val ny = p.y + dy / d * factor
        if (s.outBounce) {
            if (nx - p.radius > 0 && nx + p.radius < sim.w) p.x = nx
            if (ny - p.radius > 0 && ny + p.radius < sim.h) p.y = ny
        } else {
            p.x = nx
            p.y = ny
        }
    }

    private fun repulseClick(sim: Sim, p: Particle) {
        val s = sim.s
        if (!sim.repulseClicking) {
            p.vx = p.vxi
            p.vy = p.vyi
            return
        }
        val r3 = (s.repulseDistance / 6).pow(3)
        val dx = sim.clickX - p.x
        val dy = sim.clickY - p.y
        val d = dx * dx + dy * dy
        if (d > r3 || d < 1e-3f) return
        val force = -r3 / d
        val a = atan2(dy, dx)
        p.vx = force * cos(a)
        p.vy = force * sin(a)
        if (s.outBounce) {
            val nx = p.x + p.vx
            val ny = p.y + p.vy
            if (nx + p.radius > sim.w || nx - p.radius < 0) p.vx = -p.vx
            if (ny + p.radius > sim.h || ny - p.radius < 0) p.vy = -p.vy
        }
    }

    private var head = IntArray(0)
    private var nextLink = IntArray(0)
    private var cellOf = IntArray(0)

    /** Links, attraction and collisions between nearby particles, using a grid so large counts stay cheap. */
    private fun pairs(sim: Sim, k: Float) {
        val s = sim.s
        val ps = sim.ps
        if (ps.size < 2) return
        var maxR = 0f
        for (p in ps) maxR = max(maxR, p.radius)
        val cell = maxOf(s.lineDistance, if (s.bounce) maxR * 2 else 0f, 8f)
        var cols = max(1, ceil((sim.w + 2 * maxR) / cell).toInt() + 1)
        var rows = max(1, ceil((sim.h + 2 * maxR) / cell).toInt() + 1)
        if (cols.toLong() * rows > (1 shl 20)) { cols = 1; rows = 1 }  // absurd config: brute force
        if (head.size < cols * rows) head = IntArray(cols * rows)
        head.fill(-1, 0, cols * rows)
        if (nextLink.size < ps.size) { nextLink = IntArray(ps.size * 2); cellOf = IntArray(ps.size * 2) }
        for (i in ps.indices) {
            val cx = ((ps[i].x + maxR) / cell).toInt().coerceIn(0, cols - 1)
            val cy = ((ps[i].y + maxR) / cell).toInt().coerceIn(0, rows - 1)
            cellOf[i] = cy * cols + cx
            nextLink[i] = head[cellOf[i]]
            head[cellOf[i]] = i
        }
        for (i in ps.indices) {
            val cx = cellOf[i] % cols
            val cy = cellOf[i] / cols
            for (oy in -1..1) for (ox in -1..1) {
                val x = cx + ox
                val y = cy + oy
                if (x < 0 || y < 0 || x >= cols || y >= rows) continue
                var j = head[y * cols + x]
                while (j >= 0) {
                    if (j > i) {
                        val a = ps[i]
                        val b = ps[j]
                        val dx = a.x - b.x
                        val dy = a.y - b.y
                        val d = sqrt(dx * dx + dy * dy)
                        if (s.lines && d <= s.lineDistance) {
                            val op = s.lineOpacity - d * s.lineOpacity / s.lineDistance
                            if (op > 0) sim.addLine(a.x, a.y, b.x, b.y, s.lineColor, op, s.lineWidth)
                        }
                        if (s.attract && d <= s.lineDistance) {
                            val ax = dx / (s.rotateX * 1000) * k
                            val ay = dy / (s.rotateY * 1000) * k
                            a.vx -= ax; a.vy -= ay; b.vx += ax; b.vy += ay
                        }
                        if (s.bounce && d <= a.radius + b.radius) {
                            a.vx = -a.vx; a.vy = -a.vy; b.vx = -b.vx; b.vy = -b.vy
                        }
                    }
                    j = nextLink[j]
                }
            }
        }
    }

    // ---------------------------------------------------------------- rendering

    private fun buffer(floats: Int): FloatBuffer =
        ByteBuffer.allocateDirect(floats * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

    /** CSS background-size / background-position, as the particles.js demo page uses them. */
    private fun backgroundTransform(w: Float, h: Float, dpi: Float, pic: Picture): FloatArray {
        val iw = pic.width.toFloat()
        val ih = pic.height.toFloat()
        fun tokens(s: String) = s.split(' ').filter { it.isNotEmpty() }
        fun length(t: String, full: Float): Float {  // < 0 = auto
            if (t.isEmpty() || t == "auto") return -1f
            val v = t.trimEnd('%', 'p', 'x').toFloatOrNull() ?: return -1f
            return if (t.endsWith("%")) full * v / 100 else v * dpi
        }
        var dw: Float
        var dh: Float
        if (cfg.bgSize == "cover" || cfg.bgSize == "contain") {
            val k = if (cfg.bgSize == "cover") max(w / iw, h / ih) else min(w / iw, h / ih)
            dw = iw * k
            dh = ih * k
        } else {
            val t = tokens(cfg.bgSize)
            val a = length(t.getOrElse(0) { "auto" }, w)
            val b = length(t.getOrElse(1) { "auto" }, h)
            when {
                a < 0 && b < 0 -> { dw = iw * dpi; dh = ih * dpi }
                b < 0 -> { dw = a; dh = ih * a / iw }
                a < 0 -> { dh = b; dw = iw * b / ih }
                else -> { dw = a; dh = b }
            }
        }
        fun offset(t: String, free: Float): Float = when (t) {
            "left", "top" -> 0f
            "center" -> free * 0.5f
            "right", "bottom" -> free
            else -> {
                val v = t.trimEnd('%', 'p', 'x').toFloatOrNull() ?: 50f
                if (t.endsWith("%")) free * v / 100 else v * dpi
            }
        }
        val t = tokens(cfg.bgPosition)
        val ox = offset(t.getOrElse(0) { "50%" }, w - dw)
        val oy = offset(t.getOrElse(1) { "50%" }, h - dh)
        dw = max(dw, 1f)
        dh = max(dh, 1f)
        return floatArrayOf(w / dw, h / dh, -ox / dw, -oy / dh)
    }

    private fun render(sim: Sim, frame: Frame) {
        val c = sim.s
        // RGB rainbow: the background color joins in too (worked out here), the rest in the shaders.
        Rainbow.at(prefs.rainbow(wallpaper.id), prefs.rainbowSpeed(wallpaper.id), now, rainbow)
        bgRgb[0] = c.bgColor.r; bgRgb[1] = c.bgColor.g; bgRgb[2] = c.bgColor.b
        Rainbow.apply(rainbow, bgRgb)
        val wavePerPixel = rainbow[1] / frame.width.coerceAtLeast(1)
        for (program in intArrayOf(bgProgram, lineProgram, partProgram)) {
            GLES30.glUseProgram(program)
            GLES30.glUniform4f(GLES30.glGetUniformLocation(program, "uRainbow"), rainbow[0], wavePerPixel, rainbow[2], 0f)
        }
        GLES30.glClearColor(bgRgb[0], bgRgb[1], bgRgb[2], 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        GLES30.glEnable(GLES30.GL_BLEND)
        GLES30.glBlendFunc(GLES30.GL_ONE, GLES30.GL_ONE_MINUS_SRC_ALPHA)  // premultiplied alpha
        val w = frame.width.toFloat()
        val h = frame.height.toFloat()

        if (bg != null) {
            val x = backgroundTransform(w, h, if (sim.retinaOn) sim.pxratio else sim.drawScale, bg)
            GLES30.glUseProgram(bgProgram)
            GLES30.glUniform4f(GLES30.glGetUniformLocation(bgProgram, "uXform"), x[0], x[1], x[2], x[3])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(bgProgram, "uRepeat"), if (c.bgRepeat) 1f else 0f)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, bg.at(now).id)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(bgProgram, "tex0"), 0)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
        }
        val k = sim.drawScale

        // Lines go underneath every particle, as in particles.js.
        if (sim.lineCount > 0) {
            if (lineData.capacity() < sim.lineCount * 9) lineData = buffer(sim.lineCount * 9 * 3 / 2)
            lineData.clear()
            for (i in 0 until sim.lineCount) {
                val o = i * 9
                val l = sim.lines
                lineData.put(l[o] * k).put(l[o + 1] * k).put(l[o + 2] * k).put(l[o + 3] * k)
                    .put(l[o + 4]).put(l[o + 5]).put(l[o + 6]).put(l[o + 7]).put(l[o + 8] * k)
            }
            lineData.flip()
            GLES30.glUseProgram(lineProgram)
            GLES30.glUniform2f(GLES30.glGetUniformLocation(lineProgram, "uRes"), w, h)
            GLES30.glBindVertexArray(lineVao)
            GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, lineVbo)
            GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, sim.lineCount * 36, lineData, GLES30.GL_STREAM_DRAW)
            GLES30.glDrawArraysInstanced(GLES30.GL_TRIANGLE_STRIP, 0, 4, sim.lineCount)
        }

        if (partData.capacity() < sim.ps.size * 20) partData = buffer(sim.ps.size * 20 * 3 / 2)
        partData.clear()
        var count = 0
        val stroke = c.strokeWidth
        for (p in sim.ps) {
            val r = if (p.radiusBubble >= 0) p.radiusBubble else p.radius
            val a = if (p.opacityBubble >= 0) p.opacityBubble else p.opacity
            if (r <= 0 && stroke <= 0) continue
            var cy = p.y * k
            var hx: Float
            var hy: Float
            var radius = r
            var rin = 0f
            var n = 0f
            var rot = 0f
            var type = 0f
            var isImage = 0f
            when (p.shape) {
                Shape.Circle -> {}
                Shape.Edge -> type = 1f
                Shape.Triangle -> { type = 2f; n = 3f; radius = 2 * r / sqrt(3f); rin = radius * 0.5f }  // equilateral, side 2r
                Shape.Polygon -> {  // side = 2.66r / (n/3), flat top
                    n = c.sides
                    val side = r * 2.66f / (n / 3)
                    type = 2f; radius = side / (2 * sin(PI / n)); rin = radius * cos(PI / n); rot = PI / n
                }
                Shape.Star -> {  // star polygon {n/2}, chord = 2 * 2.66r / (n/3), a tip up
                    n = c.sides
                    val chord = r * 2 * 2.66f / (n / 3)
                    type = 2f; radius = chord / (2 * sin(2 * PI / n))
                    rin = max(radius * cos(2 * PI / n) / cos(PI / n), radius * 0.15f)
                }
                Shape.Image -> {
                    if (image == null) continue
                    // drawImage(img, x - r, y - r, 2r, 2r / ratio)
                    cy = (p.y - r + r / c.imageRatio) * k
                    isImage = 1f
                }
            }
            if (isImage > 0f) {
                hx = r * k
                hy = r / c.imageRatio * k
            } else {
                val extent = (radius + stroke * 0.5f) * k + 1.5f
                hx = extent
                hy = extent
            }
            partData.put(p.x * k).put(cy).put(hx).put(hy)
                .put(p.color.r).put(p.color.g).put(p.color.b).put(a.coerceIn(0f, 1f))
                .put(c.strokeColor.r).put(c.strokeColor.g).put(c.strokeColor.b).put(stroke * k)
                .put(type).put(radius * k).put(rin * k).put(n)
                .put(rot).put(isImage).put(0f).put(0f)
            count++
        }
        partData.flip()
        if (count > 0) {
            GLES30.glUseProgram(partProgram)
            GLES30.glUniform2f(GLES30.glGetUniformLocation(partProgram, "uRes"), w, h)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, image?.at(now)?.id ?: 0)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(partProgram, "tex0"), 0)
            GLES30.glBindVertexArray(partVao)
            GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, partVbo)
            GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, count * 80, partData, GLES30.GL_STREAM_DRAW)
            GLES30.glDrawArraysInstanced(GLES30.GL_TRIANGLE_STRIP, 0, 4, count)
        }
        GLES30.glBindVertexArray(0)
        GLES30.glDisable(GLES30.GL_BLEND)
    }

    override fun release() {
        GLES30.glDeleteProgram(partProgram)
        GLES30.glDeleteProgram(lineProgram)
        GLES30.glDeleteProgram(bgProgram)
        GLES30.glDeleteBuffers(2, intArrayOf(partVbo, lineVbo), 0)
        GLES30.glDeleteVertexArrays(2, intArrayOf(partVao, lineVao), 0)
        bg?.release()
        image?.release()
    }

    companion object {
        // The Windows shaders (src/particles.hlsl), in GLSL ES: one instanced quad per particle / line,
        // shapes drawn as anti-aliased distance fields, premultiplied alpha out.
        private const val PART_VS = """#version 300 es
uniform vec2 uRes;
layout(location = 0) in vec2 aCenter;
layout(location = 1) in vec2 aHalf;
layout(location = 2) in vec4 aFill;
layout(location = 3) in vec4 aStroke;
layout(location = 4) in vec4 aShape;
layout(location = 5) in vec4 aParam;
out vec2 vLocal;
out vec2 vUv;
flat out vec4 vFill;
flat out vec4 vStroke;
flat out vec4 vShape;
flat out vec4 vParam;
void main() {
    vec2 corner = vec2((gl_VertexID & 1) != 0 ? 1.0 : -1.0, (gl_VertexID & 2) != 0 ? 1.0 : -1.0);
    vLocal = corner * aHalf;
    vUv = corner * 0.5 + 0.5;
    vec2 px = aCenter + vLocal;
    gl_Position = vec4(px.x / uRes.x * 2.0 - 1.0, 1.0 - px.y / uRes.y * 2.0, 0.0, 1.0);
    vFill = aFill;
    vStroke = aStroke;
    vShape = aShape;
    vParam = aParam;
}
"""
        private const val PART_FS = """#version 300 es
precision highp float;
in vec2 vLocal;
in vec2 vUv;
flat in vec4 vFill;
flat in vec4 vStroke;
flat in vec4 vShape;
flat in vec4 vParam;
uniform sampler2D tex0;
out vec4 fragColor;
uniform vec4 uRainbow;  // RGB rainbow: hue angle, wave (radians per pixel across), on
vec3 rainbow(vec3 c) {
    if (uRainbow.z == 0.0) return c;
    float a = uRainbow.x + uRainbow.y * gl_FragCoord.x;
    const vec3 k = vec3(0.57735);
    float ca = cos(a);
    vec3 r = c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
    float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
    float grey = hi > 0.0 ? 1.0 - (hi - lo) / hi : 1.0;  // greys and whites take on the rainbow too
    vec3 tint = (0.5 + 0.5 * cos(a + vec3(0.0, 2.0944, 4.1888))) * dot(c, vec3(0.2126, 0.7152, 0.0722)) * 2.0;
    return mix(r, tint, grey * 0.65);
}
// Regular polygon / star with tips at radius R and inner corners at Rin; a tip points up.
float sdStarPoly(vec2 p, float R, float Rin, float n, float rot) {
    float an = 3.14159265 / n;
    float a = atan(p.x, p.y) + rot;
    float b = a - 2.0 * an * floor((a + an) / (2.0 * an));
    vec2 q = length(p) * vec2(abs(sin(b)), cos(b));
    vec2 T = vec2(0.0, R);
    vec2 I = vec2(Rin * sin(an), Rin * cos(an));
    vec2 e = I - T;
    vec2 w = q - T;
    float h = clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    float d = length(w - e * h);
    return (e.x * w.y - e.y * w.x) < 0.0 ? -d : d;
}
void main() {
    if (vParam.y > 0.5) {  // image particle, as-is (premultiplied)
        vec4 img = textureLod(tex0, vUv, 0.0);
        fragColor = vec4(min(rainbow(img.rgb), vec3(img.a)), img.a);
        return;
    }
    vec2 p = vLocal;
    float type = vShape.x, R = vShape.y;
    float d;
    if (type < 0.5) {
        d = length(p) - R;
    } else if (type < 1.5) {
        vec2 q = abs(p) - R;
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    } else {
        d = sdStarPoly(vec2(p.x, -p.y), R, vShape.z, vShape.w, vParam.x);
    }
    // Strokes first, then fills on top, as a canvas draws them.
    float fillCov = clamp(0.5 - d, 0.0, 1.0) * vFill.a;
    float sw = vStroke.w;
    float strokeCov = sw > 0.0 ? clamp(0.5 - (d - sw * 0.5), 0.0, 1.0) - clamp(0.5 - (d + sw * 0.5), 0.0, 1.0) : 0.0;
    vec3 rgb = vFill.rgb * fillCov + vStroke.rgb * strokeCov * (1.0 - fillCov);
    float a = fillCov + strokeCov * (1.0 - fillCov);
    fragColor = vec4(min(rainbow(rgb), vec3(a)), a);
}
"""
        private const val LINE_VS = """#version 300 es
uniform vec2 uRes;
layout(location = 0) in vec4 aEnds;
layout(location = 1) in vec4 aColor;
layout(location = 2) in float aWidth;
out float vAcross;
flat out float vWidth;
flat out vec4 vColor;
void main() {
    vec2 a = aEnds.xy, b = aEnds.zw;
    vec2 dir = b - a;
    float len = length(dir);
    dir = len > 1e-4 ? dir / len : vec2(1.0, 0.0);
    vec2 nrm = vec2(-dir.y, dir.x);
    float side = (gl_VertexID & 2) != 0 ? 1.0 : -1.0;
    float extent = aWidth * 0.5 + 1.0;
    vec2 px = ((gl_VertexID & 1) != 0 ? b : a) + nrm * side * extent;
    gl_Position = vec4(px.x / uRes.x * 2.0 - 1.0, 1.0 - px.y / uRes.y * 2.0, 0.0, 1.0);
    vAcross = side * extent;
    vWidth = aWidth;
    vColor = aColor;
}
"""
        private const val LINE_FS = """#version 300 es
precision highp float;
in float vAcross;
flat in float vWidth;
flat in vec4 vColor;
out vec4 fragColor;
uniform vec4 uRainbow;  // RGB rainbow: hue angle, wave (radians per pixel across), on
vec3 rainbow(vec3 c) {
    if (uRainbow.z == 0.0) return c;
    float a = uRainbow.x + uRainbow.y * gl_FragCoord.x;
    const vec3 k = vec3(0.57735);
    float ca = cos(a);
    vec3 r = c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
    float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
    float grey = hi > 0.0 ? 1.0 - (hi - lo) / hi : 1.0;  // greys and whites take on the rainbow too
    vec3 tint = (0.5 + 0.5 * cos(a + vec3(0.0, 2.0944, 4.1888))) * dot(c, vec3(0.2126, 0.7152, 0.0722)) * 2.0;
    return mix(r, tint, grey * 0.65);
}
void main() {
    float cov = clamp(vWidth * 0.5 + 0.5 - abs(vAcross), 0.0, 1.0);
    float a = vColor.a * cov;
    fragColor = vec4(min(rainbow(vColor.rgb * a), vec3(a)), a);
}
"""
        private const val BG_FS = """#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D tex0;
uniform vec4 uXform;
uniform float uRepeat;
out vec4 fragColor;
uniform vec4 uRainbow;  // RGB rainbow: hue angle, wave (radians per pixel across), on
vec3 rainbow(vec3 c) {
    if (uRainbow.z == 0.0) return c;
    float a = uRainbow.x + uRainbow.y * gl_FragCoord.x;
    const vec3 k = vec3(0.57735);
    float ca = cos(a);
    vec3 r = c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
    float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
    float grey = hi > 0.0 ? 1.0 - (hi - lo) / hi : 1.0;  // greys and whites take on the rainbow too
    vec3 tint = (0.5 + 0.5 * cos(a + vec3(0.0, 2.0944, 4.1888))) * dot(c, vec3(0.2126, 0.7152, 0.0722)) * 2.0;
    return mix(r, tint, grey * 0.65);
}
void main() {
    vec2 t = vUv * uXform.xy + uXform.zw;
    float inside = uRepeat > 0.5 ? 1.0 : step(0.0, t.x) * step(t.x, 1.0) * step(0.0, t.y) * step(t.y, 1.0);
    vec4 c = texture(tex0, t) * inside;
    fragColor = vec4(rainbow(c.rgb), c.a);
}
"""
    }
}
