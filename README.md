<p align="center"><img src="docs/logo.png" width="128" alt="LiteWallpaper logo"></p>

# LiteWallpaper

A small animated wallpaper for Windows 10/11: one exe of about 600 KB, with no runtime to install.

- **Shaders** (`.hlsl`), **particles.js effects** (`.json`), **videos** (`.mp4 .mkv .webm .mov .wmv .avi`), **GIFs**, and **images**.
- Runs on every monitor, and each monitor can have its own wallpaper.
- Draws behind the desktop icons; icons and clicks behave normally.

## Download

From the [latest release](https://github.com/mybugga/LiteWallpaper/releases/latest), get either:

- **`LiteWallpaper-<version>-setup.exe`**: the installer. It installs for you only, in `%LOCALAPPDATA%\Programs\LiteWallpaper`, without asking for admin rights, and adds LiteWallpaper to the Start menu and to Settings > Apps for uninstalling. It can also install for all users, in Program Files. Uninstalling closes the app and removes its "Start with Windows" entry, and asks whether to delete your settings too.
- **`LiteWallpaper-<version>.zip`**: the portable version. Unzip it anywhere and run `LiteWallpaper.exe`.

Both update themselves the same way.

## Updates

LiteWallpaper keeps itself up to date from this repository's releases. About a minute and a half after it starts, and then every 6 hours, it asks GitHub for the latest release. When there is a newer one, it downloads it in the background and checks the download against the SHA-256 that GitHub publishes for it. It then replaces its own files and restarts, which takes about a second. It never does this while a game or other fullscreen app is running, or while the settings window is open; it waits for the next quiet moment. Your settings and profiles live in `%APPDATA%\LiteWallpaper`, so updates never touch them.

- **Check for updates**, in the tray menu or in Settings > General next to the version number, checks right away and asks before installing.
- **Update automatically** (Settings, General) turns off the background checks. You can still update from the tray menu.
- If the app is somewhere only admins can write, such as `C:\Program Files\LiteWallpaper` (used by **Start for all users**), you get a notification instead. Choose **Install update** in the tray menu to install it, which asks for admin rights once.
- Builds you make yourself with plain `build.bat` are "dev" builds, which never update themselves.

## Staying out of the way of games

The app stops completely (no drawing, no timers, memory paged out) when any of these happen:

| When | Setting |
|---|---|
| A game or app runs fullscreen (exclusive or borderless) | `pause_on_fullscreen` |
| A listed program is running, even windowed | `pause_apps` |
| Windows cover the desktop (maximized, or several snapped) | `pause_when_covered` (per monitor) |
| On battery | `pause_on_battery` |
| PC locked, or display turned off | always |

The first line of the tray menu shows why it's paused, for example "Paused (game.exe is fullscreen)". Only windows you can actually see count as fullscreen. Hidden, cloaked or fully transparent full-screen windows, which some GPU overlays and laptop utilities leave in the foreground, are ignored.

On top of that, the process runs at below-normal CPU priority with Windows' Eco mode, at below-normal GPU scheduling priority, and at the lowest DXGI GPU thread priority. Games get the hardware first.

Measured on an RTX 4070 Ti at 2560×1440:

| State | Memory (working set) | CPU | GPU |
|---|---|---|---|
| Paused (game running) | ~1 MB | 0% | 0% |
| Shader (aurora, 30 fps, half res) | ~15 MB | ~0.2% total | ~0.2% |
| particles.js "default" (~370 particles + links) | ~7 MB | ~0.1% total | ~0% |
| particles.js "snow" (~1800 particles) | ~7 MB | ~0.2% total | ~0% |
| GIF | ~14 MB | ~0.1% total | ~0% |
| Video 1080p (hardware decode) | ~55 MB | ~0.3% total | low |

## Use

Run `LiteWallpaper.exe`. It lives in the tray: right-click it to pick a wallpaper from the **Wallpaper** menu (every bundled shader and particles preset), pause, open the app folder or your settings folder, start with Windows (for you or for everyone), or exit.

### Settings window

Double-click the tray icon, choose **Settings...**, or run `LiteWallpaper.exe` again while it's already running. Changes show on the wallpaper as you make them, and there's nothing to save.

- **Wallpaper:** pick any bundled one, or **Browse...** for your own shader, particles config, video, GIF, or image.
- **Particles:** color (or random), amount, shape, sides, size, opacity, twinkle/pulse, outline. Also lines (on/off, color, distance, width, opacity), motion (speed, direction, edge wrap/bounce, straight, bounce, attract), mouse (hover and click effects plus their distances), and background (color, image, size, position, particle image).
- **Shaders:** speed, hue, saturation, brightness, render resolution. These work on any shader, including your own.
- **Images/videos:** fit.
- **General:** frame rate, the pause rules, extra programs to pause for, start with Windows, start for all users.

### Profiles

A profile is a complete setup: wallpaper, every tweak, frame rate, and pause rules. Your `wallpaper.ini` is the **Default** profile. **Save as new...** in the settings window copies the current setup into `profiles\<name>.ini` and switches to it. From then on, every change saves into the active profile automatically. Switch profiles from the settings window or the tray's **Profile** menu.

The last profile you used is remembered and loaded on the next start. It's the very first thing the app does, before any other setting is read or anything is drawn, so you never see a different wallpaper flash first.

### Several users on one PC

Every Windows user has their own settings: wallpaper, tweaks, profiles, pause rules and start-up choice, kept in `%APPDATA%\LiteWallpaper` (tray: **Open my settings folder**). Nobody's changes affect anyone else. The first time someone runs the app, a `wallpaper.ini` (and `profiles\`) next to the exe is copied in as their starting point; after that the copy next to the exe isn't read. If two people are signed in at once, each runs their own copy, and the one in the background stays paused.

### Start with Windows

Ticking **Start with Windows** creates a Task Scheduler task, `LiteWallpaper (<your user name>)`, that starts the app the moment you sign in. The usual Run registry key is held back by Windows for several seconds after sign-in; the task isn't, so the wallpaper is up as the desktop appears. The task runs without admin rights, never times out, and keeps running on battery. If it can't be created, the Run key is used instead. Unticking removes both.

**Start for all users of this PC** (settings window or tray) asks for admin rights once and creates one task, `LiteWallpaper (All users)`, that starts the app at everyone's sign-in, in their own session with their own settings and without admin rights. Other users can't open files inside your user folder, so if the app is somewhere like your Desktop it's first copied, with its shaders and particles, to `C:\Program Files\LiteWallpaper`, and the task starts that copy. People who haven't used the app yet start with your current setup. Any user can still untick **Start with Windows** for themselves, and the app then stays off when they sign in. Unticking **Start for all users** removes the task (the copy in Program Files stays, since someone may be running it).

Your tweaks are stored in the profile's ini under `[override:<file>]`, and the preset files themselves are never changed. **Reset to defaults** removes the tweaks for the current wallpaper. The window is plain Win32, using no memory until opened, and gives everything back when closed. It uses a dark theme throughout (title bar, controls, dropdowns, the tray menu). The only exceptions are the Windows color picker, the file picker, and confirmation boxes, which follow your Windows theme. Double-click the tray icon to pause or resume. There are no hotkeys.

Settings are in `%APPDATA%\LiteWallpaper\wallpaper.ini`, which is created on first run. Saving the file applies changes immediately, and so does saving a shader file you're using.

```ini
[default]
source = shaders\aurora.hlsl   ; or C:\Videos\loop.mp4, or D:\fun.gif
fit = cover                    ; cover | contain | stretch (images & video)
scale = 0.5                    ; shader render resolution (0.1 - 1.0)

[monitor2]                     ; monitors numbered left to right
source = shaders\starfield.hlsl
```

`LiteWallpaper.exe --settings` opens the settings window, and `LiteWallpaper.exe --exit` closes a running copy (and waits until it has). `--diag` writes the desktop window layout and status changes to `LiteWallpaper.log` in your settings folder.

## particles.js effects

This is a native C++ port of [particles.js](https://github.com/VincentGarreau/particles.js) by Vincent Garreau (MIT license). There's no browser or JavaScript involved: it reads the library's JSON config files as they are. Any config exported from the [particles.js website](https://vincentgarreau.com/particles.js/) ("Download current config (json)") or found on CodePen works when you set it as `source`.

Supported features:
- **Shapes:** circle, edge, triangle, polygon (any side count), star, image (PNG/JPG/GIF, including animated GIFs), and mixed shape lists. Stroke width and color.
- **Colors:** hex, a list of hex colors, `"random"`, `{r,g,b}`, `{h,s,l}`.
- **Animation:** random or animated size and opacity (with sync).
- **Lines:** linked lines (distance, color, opacity, width).
- **Movement:** speed, 8 directions, random, straight, `out`/`bounce` edges, particle-to-particle bounce, attract (rotateX/Y), density scaling, retina detection.
- **Hover modes:** `grab`, `bubble`, `repulse`.
- **Click modes:** `push`, `remove`, `bubble`, `repulse`. Clicking empty desktop counts as a click.
- **Background:** the demo page's `config_demo` background color and image, with CSS `background-size` and `background-position`. Image paths are relative to the `.json`.

Bundled presets in `particles\`, all from the particles.js site: `default`, `nasa`, `bubble`, `snow`, `nyancat2` (the site's "Nyan Cat"), plus the site's hidden `nyancat` and `star`. The NASA logo and Nyan Cat images in `particles\assets` are the ones the demo page loads; they belong to their owners and are only here for your personal wallpaper.

The mouse is read by polling the cursor once per frame, with no global mouse hook, so it adds no input lag anywhere. Particles move by elapsed time, so they keep the same speed at any `fps`. They run at your `fps` setting; 60 looks smoother and costs a little more CPU.

## Writing shaders

Write a function `float4 mainImage(float2 fragCoord)` in HLSL. You get `iResolution` (pixels), `iTime` (seconds), and `iFrame`. `fragCoord` starts at the bottom-left, like Shadertoy. `vec2/3/4`, `mix`, `fract`, and `mod` also work, which makes porting simple Shadertoy shaders easier. If a shader fails to compile, the tray shows the error and a built-in fallback plays instead.

A shader can also use images: a line `// texture: assets/photo.png` (relative to the shader) binds it as `iChannel0`, and `// texture1:` binds a second one as `iChannel1`; sample with `iChannel0.Sample(iSampler, uv)`. Shaders can `#include` files next to them. Transparent PNGs come in with premultiplied alpha; animated GIFs play. A line `// scale: 1` sets that shader's render resolution, overriding the general setting, which a photo needs to stay sharp.

Bundled astronaut wallpapers (a photo of an astronaut on the right, real space photography behind, with slow camera drift, stars drifting past, shooting stars and suit lights):
- `astronaut`: the Milky Way and a sun glint on the visor (all procedural).
- `astronaut_blackhole`: NASA's black hole visualization (NASA Goddard / J. Schnittman, SVS 14619), its disk flowing.
- `astronaut_pulsar`: the Crab Nebula (NASA/CXC/SAO, STScI, JPL-Caltech) with its pulsar flashing and sweeping beams.
- `astronaut_nebula`: the Pillars of Creation (NASA, ESA, Hubble Heritage Team, 2014), tinted emerald.
- `astronaut_galaxy`: the Whirlpool Galaxy M51 (NASA, ESA, S. Beckwith, Hubble Heritage Team), tinted violet.

Bundled planet wallpapers bring a still picture of a ringed planet to life: light streams round the rings with glints riding along, glowing cracks pulse, the flare on the planet's edge pulses, nebulae shimmer and crystals sparkle (`planet.hlsli`): `planet_cosmic`, `planet_ember`, `planet_ice`, `planet_sapphire`, `planet_neon`, `planet_eclipse` (flickering corona), `planet_crystal`, `planet_storm`.

Other picture wallpapers: `katana` (sakura petals falling around a katana, a gleam running down the blade), `sakura_pond` (a neon cherry tree swaying over rippling water, glowing petals falling into it) and `tree` (a green tree swaying in the wind, leaves fluttering and falling). Their petals and leaves are small 3D objects that tumble as they fall (`falling.hlsli`). Also `mech` (a robot in red smoke, its lights pulsing and a scan running along its visor), `car` (a supercar in the rain, puddles rippling, smoke rolling, taillights sweeping) and `dragon` (molten cracks flowing, smoke streaming from its jaws, embers rising, breathing and flexing its wings); their smoke, embers, rain and ripples come from `fx.hlsli`. And `ribbon`: glass ribbons waving like silk, pink and blue light streaming to the right through them, pulses racing along their edges and sparks flying off them. And `watch`: a skeleton pocket watch whose seconds hand beats round five times a second in time with its swinging balance wheel, its barrel turning, a glint sliding over the glass and dust drifting in the warm light. And `chess`: a cracked marble king with molten gold flowing up its cracks, light running out along the cracked floor, sparks rising and the broken shards floating round it. And `skull`: smoke streaming up and curling round a skull, red light flickering like firelight and embers glowing in its eyes. And `bottle`: a storm in a corked bottle, with lightning striking every few seconds (the painted bolt or a new one), the clouds lighting up from inside, rain falling in the glass and the clouds churning. And `meteor`: a burning rock floating in the dark, lava flowing in its cracks, embers bursting out, smoke and heat haze rising off it. And `manta`: a glowing manta ray flapping its wings, waves of light running out along its edges, glowing particles shed in its wake and plankton drifting by. And `snowglobe`: snow swirling inside a glass globe, smoke curling from the cabin chimney, firelight flickering in the windows and mist drifting round the mountain. And `raven`: a clockwork raven turning its head in quick little moves, breathing, its shoulder gear turning, its eye's pupil narrowing and widening and the wind ruffling its feathers. And `waterfall`: a tiny waterfall in a glass cube pouring and foaming, spray leaping, rings rippling across the pool, light shimmering on its bottom, mist rising and ferns swaying. And `lighthouse`: a lighthouse whose beam turns round (sweeping left, passing behind the tower, sweeping right and flashing as it faces you) over a rolling sea, with waves breaking on the rocks. And `prism`: a hanging prism swaying on its cord with the rainbow swinging after it, pulses of light running along the beam and out through the colours, and dust glinting in the light. And `feather`: a burning feather floating in the dark, fire creeping along its edge, flames licking up, embers breaking off and smoke streaming upward. And `crystals`: glowing green and purple crystals with light rising through them, glints flashing on their facets, the gold veins shimmering and broken-off bits floating in the air. And `armillary`: steel rings round a glowing core, light sweeping round them as they spin, energy rippling out of the core and sparks orbiting inside its glass. And `guitar`: a black electric guitar whose strings are strummed every few seconds and vibrate, with blue light running round its edge, a sheen over the gloss and glints on the chrome. And `ghostship`: a ragged galleon rocking on the swell, its torn sails and pennants fluttering, lanterns flickering, fog rolling round it and the waves shimmering with lantern light. And `projector`: an old film projector with both reels turning, the film running, the beam flickering frame by frame and dust drifting in the light. And `foxmask`: a kitsune mask swaying on its cords, its tassels swinging, ribbons fluttering, bells glinting and smoke curling round it. And `book`: an old book floating open, golden sparks pouring up out of its pages, the light inside pulsing, golden haze rising and the page tips fluttering. And `door`: stone steps climbing through fog to an open door, its light flickering like a fire beyond, soft rays shifting through the haze, fog rolling down the steps and dust glittering in the light.

The NASA/ESA images are public domain; the astronaut photos are your own images. Other shaders: `aurora`, `waves`, `plasma`, `starfield`, `gradient` (the cheapest).

## Build

`build.bat` needs Visual Studio 2022 or newer with "Desktop development with C++". It finds the compiler itself. `build.bat 1.2.3` stamps a version into the exe; without one you get a "dev" build.

## Releasing

Push a tag such as `v1.2.3`. The `Release` workflow builds the exe with that version, zips it with `shaders\` and `particles\` as `LiteWallpaper-1.2.3.zip`, builds the installer `LiteWallpaper-1.2.3-setup.exe` from the same files (`installer\LiteWallpaper.iss`, Inno Setup 6), and publishes a GitHub release with both. Every installed copy then picks it up through the updater. Releases are only ever built on GitHub, and both workflows run `scripts/check-binary.ps1`, which fails the build if the exe contains a user name, computer name, user-profile path or debug-symbols path. You can also start the workflow by hand from the Actions tab and type the version in.

## How it works

Explorer is sent the undocumented `0x052C` message, which makes it create a layer between the icons and the static wallpaper. On Windows 11 24H2 and later that layer is a child of `Progman`, and the wallpaper window is placed directly below `SHELLDLL_DefView`. On older builds it is the top-level `WorkerW` that follows the icon window. Each monitor gets a child window with a Direct3D 11 flip-model swap chain. Shaders render at `scale` and DXGI stretches them up. Video uses the Media Foundation media engine, decodes on the GPU, and copies frames straight into the swap chain with the audio track deselected. GIF frames are decoded one at a time onto a single canvas. If Explorer restarts or the displays change, everything is rebuilt automatically.
