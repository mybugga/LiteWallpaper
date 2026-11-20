package io.github.mybugga.litewallpaper

import android.annotation.SuppressLint
import android.app.WallpaperManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.SurfaceTexture
import android.os.Bundle
import android.util.LruCache
import android.view.MotionEvent
import android.view.Surface
import android.view.TextureView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
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

private val Bg = Color(0xFF0E0E10)
private val Field = Color(0xFF1C1C20)
private val TextColor = Color(0xFFF2F2F4)
private val Body = Color(0xFFB9B9C0)
private val Dim = Color(0xFF8D8D95)
private val Red = Color(0xFFFF3B3B)
private val RedText = Color(0xFFFF5A5A)

/** The gallery: the selected wallpaper plays large with its details; every wallpaper is a tile below. */
class MainActivity : ComponentActivity() {
    private var resumed by mutableStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Red, background = Bg, surface = Field, onSurface = TextColor)) {
                Gallery(resumed)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        resumed++  // coming back from the system's wallpaper screen: "In use" may have changed
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
    var selected by remember { mutableStateOf(Catalog.find(context, prefs.wallpaper)) }
    var tab by remember { mutableStateOf(0) }
    var customizing by remember { mutableStateOf(false) }
    var inUse by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(resumed) { inUse = if (ourWallpaperActive(context)) prefs.wallpaper else null }

    val shown = all.filter {
        tab == 0 || (tab == 1 && it.kind == Wallpaper.Kind.Shader) || (tab == 2 && it.kind == Wallpaper.Kind.Particles)
    }
    val shaders = all.count { it.kind == Wallpaper.Kind.Shader }

    LazyVerticalGrid(
        columns = GridCells.Fixed(3),
        modifier = Modifier.fillMaxSize().background(Bg),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column(Modifier.windowInsetsPadding(WindowInsets.statusBars)) {
                UpdateBanner()
                Hero(selected, inUse == selected.id, onUse = { useWallpaper(context, selected); inUse = if (ourWallpaperActive(context)) selected.id else inUse },
                    onCustomize = { customizing = true })
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                listOf("All ${all.size}", "Shaders $shaders", "Particles ${all.size - shaders}").forEachIndexed { i, label ->
                    Column(Modifier.clickable { tab = i }) {
                        Text(label, color = if (tab == i) TextColor else Color(0xFF9A9AA2), fontSize = 15.sp,
                            fontWeight = if (tab == i) FontWeight.SemiBold else FontWeight.Normal)
                        Box(Modifier.padding(top = 6.dp).height(3.dp).width(if (tab == i) 28.dp else 0.dp).background(Red, RoundedCornerShape(2.dp)))
                    }
                }
            }
        }
        items(shown, key = { it.id }) { wp ->
            Tile(wp, wp.id == selected.id, wp.id == inUse) { selected = wp }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Spacer(Modifier.windowInsetsPadding(WindowInsets.navigationBars))
        }
    }

    if (customizing) {
        ModalBottomSheet(onDismissRequest = { customizing = false }, containerColor = Color(0xFF16161A)) {
            Customize(selected, prefs)
        }
    }
}

@Composable
private fun Hero(wp: Wallpaper, inUse: Boolean, onUse: () -> Unit, onCustomize: () -> Unit) {
    val config = LocalConfiguration.current
    val screenAspect = config.screenWidthDp.toFloat() / config.screenHeightDp.coerceAtLeast(1)
    Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        LivePreview(wp, Modifier.weight(0.46f).aspectRatio(screenAspect).clip(RoundedCornerShape(18.dp)).border(1.dp, Color(0x14FFFFFF), RoundedCornerShape(18.dp)))
        Column(Modifier.weight(0.54f).padding(top = 4.dp)) {
            Text(if (wp.kind == Wallpaper.Kind.Particles) "PARTICLES · INTERACTIVE" else "SHADER · ANIMATED",
                color = RedText, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.6.sp)
            Text(wp.name, color = TextColor, fontSize = 28.sp, fontWeight = FontWeight.Bold, lineHeight = 32.sp,
                modifier = Modifier.padding(top = 4.dp, bottom = 8.dp))
            Text(wp.description, color = Body, fontSize = 13.sp, lineHeight = 19.sp, maxLines = 7, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(16.dp))
            if (inUse) {
                OutlinedButton(onClick = onUse, modifier = Modifier.fillMaxWidth(), border = BorderStroke(1.dp, Red.copy(alpha = 0.6f)),
                    shape = RoundedCornerShape(12.dp)) { Text("✓  In use", color = TextColor) }
            } else {
                Button(onClick = onUse, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE82828), contentColor = Color.White)) {
                    Text("Set as wallpaper", fontWeight = FontWeight.SemiBold)
                }
            }
            OutlinedButton(onClick = onCustomize, modifier = Modifier.fillMaxWidth().padding(top = 8.dp), shape = RoundedCornerShape(12.dp),
                border = BorderStroke(1.dp, Color(0x2EFFFFFF))) { Text("Customize", color = TextColor) }
        }
    }
}

/** The selected wallpaper, live, drawn by the same renderer the wallpaper uses. Particle effects can be touched. */
@SuppressLint("ClickableViewAccessibility")
@Composable
private fun LivePreview(wp: Wallpaper, modifier: Modifier) {
    val context = LocalContext.current
    val renderer = remember { GlRenderer(context, "preview") }
    DisposableEffect(Unit) { onDispose { renderer.release() } }
    LaunchedEffect(wp.id) { renderer.setWallpaper(wp) }
    val current by rememberUpdatedState(wp)
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
    AndroidView(modifier = modifier.background(Color.Black), factory = { ctx ->
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
            setOnTouchListener { v, e ->
                if (current.kind != Wallpaper.Kind.Particles) return@setOnTouchListener false
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        v.parent?.requestDisallowInterceptTouchEvent(true)  // play, don't scroll the gallery
                        renderer.touch(e.x, e.y, down = true, held = true)
                    }
                    MotionEvent.ACTION_MOVE -> renderer.touch(e.x, e.y, down = false, held = true)
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> renderer.touch(e.x, e.y, down = false, held = false)
                }
                true
            }
        }
    })
}

@Composable
private fun Tile(wp: Wallpaper, selected: Boolean, inUse: Boolean, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick)) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(9f / 16f).clip(RoundedCornerShape(12.dp)).background(Field)
                .border(if (selected) 2.dp else 1.dp, if (selected) Red else Color(0x12FFFFFF), RoundedCornerShape(12.dp)),
        ) {
            Thumbnail(wp.thumbnail, Modifier.fillMaxSize())
            if (inUse) {
                Row(Modifier.padding(6.dp).background(Color(0x99000000), RoundedCornerShape(10.dp)).padding(horizontal = 7.dp, vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(6.dp).background(Red, CircleShape))
                    Text("In use", color = TextColor, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 5.dp))
                }
            }
        }
        Text(wp.name, color = if (selected) TextColor else Color(0xFFCFCFD4), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp))
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Customize(wp: Wallpaper, prefs: Prefs) {
    Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 28.dp)) {
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
            Text("Particle effects follow their particles.js settings. Touch your home screen to play with them.",
                color = Body, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
        }

        HorizontalDivider(Modifier.padding(vertical = 16.dp), color = Color(0x1AFFFFFF))
        Text("All wallpapers", color = TextColor, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        var fps by remember { mutableStateOf(prefs.fps) }
        Text("Frame rate", color = Body, fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp, bottom = 6.dp))
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
    Column(
        Modifier.fillMaxWidth().padding(bottom = 10.dp).background(Brush.horizontalGradient(listOf(Color(0x33FF3B3B), Color(0x14FF3B3B))), RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("LiteWallpaper ${r.version} is available", color = TextColor, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            if (progress < 0f) {
                Button(onClick = {
                    progress = 0f
                    error = null
                    scope.launch {
                        runCatching { Updater.download(context, r) { p -> progress = p } }
                            .onSuccess { Updater.install(context, it); progress = -1f }
                            .onFailure { error = it.message; progress = -1f }
                    }
                }, shape = RoundedCornerShape(10.dp), colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE82828))) { Text("Update") }
            }
        }
        if (progress >= 0f) LinearProgressIndicator(progress = { progress }, color = Red, modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
        error?.let { Text(it, color = RedText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp)) }
    }
}
