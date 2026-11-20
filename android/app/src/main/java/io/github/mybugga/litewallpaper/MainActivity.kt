package io.github.mybugga.litewallpaper

import android.Manifest
import android.app.WallpaperManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.SurfaceTexture
import android.os.Build
import android.os.Bundle
import android.util.LruCache
import android.view.Surface
import android.view.TextureView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs

private val Sheet = Color(0xFF16161A)
private val TextColor = Color(0xFFF2F2F4)
private val Body = Color(0xFFB9B9C0)
private val Dim = Color(0xFF8D8D95)
private val Red = Color(0xFFFF3B3B)
private val RedText = Color(0xFFFF5A5A)
private val ButtonRed = Color(0xFFE82828)

/**
 * The gallery: the selected wallpaper fills the screen, playing live. Swipe sideways (or tap the strip
 * at the bottom) to go through them; set it or customize it from the bottom, app settings behind the gear.
 */
class MainActivity : ComponentActivity() {
    private var resumed by mutableStateOf(0)
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        // Light status and navigation bar icons: they sit over the wallpaper.
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Red, background = Color.Black, surface = Sheet, onSurface = TextColor)) {
                Gallery(resumed)
            }
        }
        // Update notifications need Android 13+'s permission: asked once, on first launch.
        val prefs = Prefs(this)
        if (Build.VERSION.SDK_INT >= 33 && Updater.supported(this) && prefs.updateNotifications && !prefs.askedNotifications &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            prefs.askedNotifications = true
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        UpdateCheckJob.sync(this)
        if (intent?.action == Updater.ACTION_INSTALL_STATUS) Updater.onInstallStatus(this, intent)
    }

    // Android's installer reporting on an update (see Updater.install).
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Updater.ACTION_INSTALL_STATUS) Updater.onInstallStatus(this, intent)
    }

    override fun onResume() {
        super.onResume()
        resumed++  // coming back from the system's wallpaper screen: "In use" may have changed
        UpdateCheckJob.clear(this)
    }
}

private fun ourWallpaperActive(context: Context) =
    WallpaperManager.getInstance(context).wallpaperInfo?.packageName == context.packageName

private fun useWallpaper(context: Context, wp: Wallpaper) {
    Prefs(context).wallpaper = wp.id  // the wallpaper service switches as soon as this changes
    if (ourWallpaperActive(context)) {
        Toast.makeText(context, "${wp.name} is your wallpaper now", Toast.LENGTH_SHORT).show()
        return
    }
    val component = ComponentName(context, LiteWallpaperService::class.java)
    val intent = Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER)
        .putExtra(WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT, component)
    runCatching { context.startActivity(intent) }
        .onFailure { runCatching { context.startActivity(Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER)) } }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Gallery(resumed: Int) {
    val context = LocalContext.current
    val prefs = remember { Prefs(context) }
    val all = remember { Catalog.all(context) }
    var index by rememberSaveable { mutableIntStateOf(all.indexOf(Catalog.find(context, prefs.wallpaper)).coerceAtLeast(0)) }
    val selected = all[index]
    var customizing by remember { mutableStateOf(false) }
    var settingsOpen by remember { mutableStateOf(false) }
    var inUse by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(resumed) { inUse = if (ourWallpaperActive(context)) prefs.wallpaper else null }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        LivePreview(selected, onSwipe = { step -> index = (index + step + all.size) % all.size }, Modifier.fillMaxSize())
        // Shade at the top and bottom so the text reads over any wallpaper.
        Box(Modifier.fillMaxWidth().height(150.dp).background(Brush.verticalGradient(listOf(Color(0x99000000), Color.Transparent))))
        Box(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().fillMaxHeight(0.5f)
                .background(Brush.verticalGradient(0f to Color.Transparent, 0.45f to Color(0xC4000000), 1f to Color(0xEB000000))),
        )

        Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(start = 18.dp, end = 6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("LiteWallpaper", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                IconButton(onClick = { settingsOpen = true }) { Icon(Icons.Filled.Settings, "Settings", tint = Color.White) }
            }
            Row(Modifier.fillMaxWidth().padding(end = 12.dp)) {
                Spacer(Modifier.weight(1f))
                Text("${index + 1} / ${all.size}", color = Color(0xFFDDDDE2), fontSize = 11.sp,
                    modifier = Modifier.background(Color(0x66000000), RoundedCornerShape(9.dp)).padding(horizontal = 8.dp, vertical = 3.dp))
            }
            Box(Modifier.padding(end = 12.dp, top = 8.dp)) { UpdateBanner() }
        }

        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(bottom = 12.dp)) {
            Column(Modifier.padding(horizontal = 18.dp)) {
                Text(if (selected.kind == Wallpaper.Kind.Particles) "PARTICLES · INTERACTIVE" else "SHADER · ANIMATED",
                    color = RedText, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.6.sp)
                Text(selected.name, color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Bold, lineHeight = 34.sp,
                    modifier = Modifier.padding(top = 2.dp, bottom = 4.dp))
                Text(selected.description, color = Color(0xFFD3D3D8), fontSize = 13.sp, lineHeight = 19.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
                Row(Modifier.padding(top = 14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    val modifier = Modifier.weight(1f).height(48.dp)
                    if (inUse == selected.id) {
                        OutlinedButton(onClick = { useWallpaper(context, selected) }, modifier, shape = RoundedCornerShape(14.dp),
                            border = BorderStroke(1.dp, Red.copy(alpha = 0.7f))) { Text("✓  In use", color = Color.White, fontWeight = FontWeight.SemiBold) }
                    } else {
                        Button(onClick = { useWallpaper(context, selected); if (ourWallpaperActive(context)) inUse = selected.id }, modifier,
                            shape = RoundedCornerShape(14.dp), colors = ButtonDefaults.buttonColors(containerColor = ButtonRed, contentColor = Color.White)) {
                            Text("Set as wallpaper", fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                        }
                    }
                    Box(
                        Modifier.size(48.dp).clip(RoundedCornerShape(14.dp)).background(Color(0x4D000000))
                            .border(1.dp, Color(0x4DFFFFFF), RoundedCornerShape(14.dp)).clickable { customizing = true },
                        contentAlignment = Alignment.Center,
                    ) { SlidersGlyph() }
                }
            }
            Strip(all, index, inUse) { index = it }
        }
    }

    if (customizing) {
        // No dimming: the wallpaper stays visible above the sheet, so changes show as you make them.
        ModalBottomSheet(onDismissRequest = { customizing = false }, containerColor = Sheet, scrimColor = Color.Transparent) {
            WallpaperTweaks(selected, prefs)
        }
    }
    if (settingsOpen) {
        ModalBottomSheet(onDismissRequest = { settingsOpen = false }, containerColor = Sheet) { AppSettings(prefs) }
    }
}

/** The "customize" icon: three sliders. */
@Composable
private fun SlidersGlyph() {
    Canvas(Modifier.size(20.dp)) {
        val stroke = 2.dp.toPx()
        listOf(0.22f to 0.66f, 0.5f to 0.34f, 0.78f to 0.74f).forEach { (y, knob) ->
            val cy = size.height * y
            drawLine(Color.White, Offset(size.width * 0.06f, cy), Offset(size.width * 0.94f, cy), stroke, StrokeCap.Round)
            drawCircle(Color(0xFF2A2A2E), 3.4.dp.toPx(), Offset(size.width * knob, cy))
            drawCircle(Color.White, 3.4.dp.toPx(), Offset(size.width * knob, cy), style = Stroke(stroke))
        }
    }
}

/** Every wallpaper as a small tile; the selected one is outlined, the one in use has a red dot. */
@Composable
private fun Strip(all: List<Wallpaper>, index: Int, inUse: String?, onPick: (Int) -> Unit) {
    val state = rememberLazyListState()
    LaunchedEffect(index) { state.animateScrollToItem((index - 3).coerceAtLeast(0)) }
    LazyRow(
        state = state, modifier = Modifier.padding(top = 14.dp),
        contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        itemsIndexed(all, key = { _, w -> w.id }) { i, w ->
            val sel = i == index
            Box(
                Modifier.width(44.dp).height(78.dp).graphicsLayer { alpha = if (sel) 1f else 0.72f }
                    .border(if (sel) 2.dp else 0.dp, if (sel) Red else Color.Transparent, RoundedCornerShape(10.dp))
                    .padding(if (sel) 3.dp else 0.dp).clip(RoundedCornerShape(if (sel) 7.dp else 10.dp))
                    .background(Color(0xFF1C1C20)).clickable { onPick(i) },
            ) {
                Thumbnail(w.thumbnail, Modifier.fillMaxSize())
                if (w.id == inUse) Box(Modifier.align(Alignment.TopEnd).padding(4.dp).size(7.dp).background(Red, CircleShape))
            }
        }
    }
}

/**
 * The selected wallpaper, full screen and live, drawn by the same renderer the wallpaper uses. Its
 * thumbnail covers it until the first frame is ready (a big shader takes a moment to compile). Swipe
 * sideways for the next one; particle effects can be played with as on the home screen.
 */
@Composable
private fun LivePreview(wp: Wallpaper, onSwipe: (Int) -> Unit, modifier: Modifier) {
    val context = LocalContext.current
    val renderer = remember { GlRenderer(context, "preview") }
    var shownId by remember { mutableStateOf<String?>(null) }
    DisposableEffect(Unit) {
        renderer.onFirstFrame = { shownId = it }
        onDispose {
            renderer.onFirstFrame = null
            renderer.release()
        }
    }
    LaunchedEffect(wp.id) { renderer.setWallpaper(wp) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> renderer.setVisible(true)
                Lifecycle.Event.ON_PAUSE -> renderer.setVisible(false)
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    val current by rememberUpdatedState(wp)
    val swipe by rememberUpdatedState(onSwipe)

    Box(modifier) {
        AndroidView(modifier = Modifier.fillMaxSize(), factory = { ctx ->
            TextureView(ctx).apply {
                isOpaque = true
                surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                    private var surface: Surface? = null
                    override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
                        surface = Surface(st).also { renderer.setSurface(it) }
                        renderer.setSize(w, h)
                    }
                    override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) { renderer.setSize(w, h) }
                    override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                        renderer.surfaceGone()
                        surface?.release()
                        return true
                    }
                    override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
                }
            }
        })
        val loading = shownId != wp.id
        val cover by animateFloatAsState(if (loading) 1f else 0f, if (loading) snap() else tween(280), label = "cover")
        if (cover > 0f) Thumbnail(wp.thumbnail, Modifier.fillMaxSize().graphicsLayer { alpha = cover })

        // Sideways swipes change the wallpaper; otherwise a finger on a particle effect is the mouse
        // (held = hover, tap = click), as on the home screen.
        Box(Modifier.fillMaxSize().pointerInput(Unit) {
            val slop = viewConfiguration.touchSlop
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val particles = current.kind == Wallpaper.Kind.Particles
                var pos = down.position
                var swiping = false
                if (particles) renderer.touch(pos.x, pos.y, down = false, held = true)
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    pos = change.position
                    val dx = pos.x - down.position.x
                    if (!swiping && abs(dx) > slop * 2 && abs(dx) > abs(pos.y - down.position.y)) {
                        swiping = true
                        if (particles) renderer.touch(pos.x, pos.y, down = false, held = false)
                    }
                    if (!swiping && particles) renderer.touch(pos.x, pos.y, down = false, held = true)
                    change.consume()
                    if (!change.pressed) break
                }
                val dx = pos.x - down.position.x
                when {
                    swiping && dx < -size.width * 0.12f -> swipe(1)
                    swiping && dx > size.width * 0.12f -> swipe(-1)
                    particles && !swiping -> renderer.touch(pos.x, pos.y, down = true, held = false)
                }
            }
        })
    }
}

private object Thumbs {
    // 16-bit pixels: all 52 thumbnails fit in about 15 MB.
    private val cache = object : LruCache<String, ImageBitmap>(16 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 2
    }
    private val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.RGB_565 }

    fun get(context: Context, path: String): ImageBitmap? = cache.get(path) ?: runCatching {
        context.assets.open(path).use { BitmapFactory.decodeStream(it, null, options) }?.asImageBitmap()
    }.getOrNull()?.also { cache.put(path, it) }
}

@Composable
private fun Thumbnail(path: String, modifier: Modifier) {
    val context = LocalContext.current
    val bmp by produceState<ImageBitmap?>(null, path) { value = withContext(Dispatchers.IO) { Thumbs.get(context, path) } }
    bmp?.let { Image(it, contentDescription = null, contentScale = ContentScale.Crop, modifier = modifier) }
}

@Composable
private fun SheetColumn(content: @Composable () -> Unit) {
    Column(
        Modifier.verticalScroll(rememberScrollState()).windowInsetsPadding(WindowInsets.navigationBars)
            .padding(horizontal = 24.dp).padding(bottom = 20.dp),
    ) { content() }
}

/** This wallpaper's own speed and colours, as in the Windows settings window. */
@Composable
private fun WallpaperTweaks(wp: Wallpaper, prefs: Prefs) = SheetColumn {
    Text("Customize ${wp.name}", color = TextColor, fontSize = 20.sp, fontWeight = FontWeight.Bold)
    if (wp.kind == Wallpaper.Kind.Shader) {
        var speed by remember(wp.id) { mutableFloatStateOf(prefs.speed(wp.id)) }
        var hue by remember(wp.id) { mutableFloatStateOf(prefs.hue(wp.id)) }
        var sat by remember(wp.id) { mutableFloatStateOf(prefs.saturation(wp.id)) }
        var bright by remember(wp.id) { mutableFloatStateOf(prefs.brightness(wp.id)) }
        SliderRow("Speed", "${(speed * 100).toInt()}%", speed, 0f..3f) { speed = it; prefs.setTweak("speed", wp.id, it) }
        SliderRow("Hue", "${hue.toInt()}°", hue, 0f..360f) { hue = it; prefs.setTweak("hue", wp.id, it) }
        SliderRow("Saturation", "${(sat * 100).toInt()}%", sat, 0f..2f) { sat = it; prefs.setTweak("saturation", wp.id, it) }
        SliderRow("Brightness", "${(bright * 100).toInt()}%", bright, 0f..2f) { bright = it; prefs.setTweak("brightness", wp.id, it) }
        TextButton(onClick = { prefs.resetTweaks(wp.id); speed = 1f; hue = 0f; sat = 1f; bright = 1f }) { Text("Reset to defaults", color = RedText) }
    } else {
        Text("Particle effects follow their particles.js settings. Touch the screen to play with them, here and on your home screen.",
            color = Body, fontSize = 13.sp, lineHeight = 19.sp, modifier = Modifier.padding(top = 8.dp))
    }
}

/** Settings for every wallpaper, and updates. */
@Composable
private fun AppSettings(prefs: Prefs) = SheetColumn {
    Text("Settings", color = TextColor, fontSize = 20.sp, fontWeight = FontWeight.Bold)
    var fps by remember { mutableStateOf(prefs.fps) }
    Text("Frame rate", color = Body, fontSize = 13.sp, modifier = Modifier.padding(top = 14.dp, bottom = 6.dp))
    val rates = listOf(15, 24, 30, 60)
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        rates.forEachIndexed { i, r ->
            SegmentedButton(selected = fps == r, onClick = { fps = r; prefs.fps = r },
                shape = SegmentedButtonDefaults.itemShape(i, rates.size),
                colors = SegmentedButtonDefaults.colors(activeContainerColor = Red.copy(alpha = 0.25f), activeContentColor = TextColor,
                    inactiveContainerColor = Color.Transparent, inactiveContentColor = Body)) { Text("$r fps", fontSize = 12.sp) }
        }
    }
    var resolution by remember { mutableFloatStateOf(prefs.resolution) }
    SliderRow("Resolution", "${(resolution * 100).toInt()}%", resolution, 0.3f..1f) { resolution = it; prefs.resolution = it }
    var saver by remember { mutableStateOf(prefs.pauseInBatterySaver) }
    SwitchRow("Pause in battery saver", saver) { saver = it; prefs.pauseInBatterySaver = it }
    var pages by remember { mutableStateOf(prefs.followPages) }
    SwitchRow("Scroll with home screen pages", pages) { pages = it; prefs.followPages = it }
    Text("Lower frame rate and resolution use less battery. The wallpaper never draws while an app or game covers it.",
        color = Dim, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.padding(top = 10.dp))

    val context = LocalContext.current
    if (Updater.supported(context)) {
        HorizontalDivider(Modifier.padding(vertical = 16.dp), color = Color(0x1AFFFFFF))
        Text("Updates", color = TextColor, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (!granted) Toast.makeText(context, "Allow notifications for LiteWallpaper in Android's settings to get them", Toast.LENGTH_LONG).show()
        }
        var notify by remember { mutableStateOf(prefs.updateNotifications) }
        SwitchRow("Tell me when there's an update", notify) {
            notify = it
            prefs.updateNotifications = it
            UpdateCheckJob.sync(context)
            if (it && Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) ask.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        Text("You have version ${Updater.currentVersion(context)}. It checks for a newer one about once a day, and every time you open the app.",
            color = Dim, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun SliderRow(label: String, value: String, v: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Column(Modifier.padding(top = 10.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Text(label, color = Body, fontSize = 13.sp, modifier = Modifier.weight(1f))
            Text(value, color = TextColor, fontSize = 13.sp)
        }
        Slider(value = v, onValueChange = onChange, valueRange = range,
            colors = SliderDefaults.colors(thumbColor = Red, activeTrackColor = Red, inactiveTrackColor = Color(0x33FFFFFF)))
    }
}

@Composable
private fun SwitchRow(label: String, on: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Body, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Switch(checked = on, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = Red))
    }
}

/** "Version x is available" with an Update button, when GitHub has a newer release. */
@Composable
private fun UpdateBanner() {
    val context = LocalContext.current
    if (!Updater.supported(context)) return
    val scope = rememberCoroutineScope()
    var release by remember { mutableStateOf<Updater.Release?>(null) }
    var progress by remember { mutableStateOf(-1f) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { release = runCatching { Updater.check(context) }.getOrNull() }
    val r = release ?: return
    Column(Modifier.fillMaxWidth().background(Color(0xCC141418), RoundedCornerShape(14.dp)).padding(start = 14.dp, end = 10.dp, top = 8.dp, bottom = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("LiteWallpaper ${r.version} is available", color = TextColor, fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            if (progress < 0f) {
                Button(onClick = {
                    progress = 0f
                    error = null
                    scope.launch {
                        runCatching { Updater.install(context, Updater.download(context, r) { p -> progress = p }) }
                            .onFailure { error = it.message }
                        progress = -1f
                    }
                }, shape = RoundedCornerShape(10.dp), colors = ButtonDefaults.buttonColors(containerColor = ButtonRed, contentColor = Color.White)) {
                    Text("Update", fontWeight = FontWeight.SemiBold)
                }
            }
        }
        if (progress >= 0f) LinearProgressIndicator(progress = { progress }, color = Red, modifier = Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp))
        error?.let { Text(it, color = RedText, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp)) }
    }
}
