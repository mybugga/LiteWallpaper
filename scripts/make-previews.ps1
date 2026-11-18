# Makes the animated previews in docs\previews from the wallpapers themselves.
#   powershell -ExecutionPolicy Bypass -File scripts\make-previews.ps1 [-Exe LiteWallpaper.exe] [-Names ribbon,skull]
# Needs ffmpeg on PATH. Each wallpaper is drawn offscreen by "LiteWallpaper.exe --render" at twice the
# GIF size, then scaled down with its own palette; the end fades into the beginning, so the GIF
# loops without a jump.
param(
    [string] $Exe = (Join-Path $PSScriptRoot '..\LiteWallpaper.exe'),
    [string[]] $Names = @('ribbon', 'skull', 'car', 'sakura_pond', 'snowglobe', 'waterfall', 'astronaut_galaxy', 'watch', 'planet_neon'),
    [int] $Width = 360,
    [int] $Fps = 12,
    [double] $Seconds = 5,
    [double] $Fade = 0.6
)
$ErrorActionPreference = 'Stop'
$Names = $Names | ForEach-Object { $_ -split ',' } | Where-Object { $_ }  # "-Names a,b" from cmd arrives as one string
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$out = Join-Path $root 'docs\previews'
New-Item -ItemType Directory -Force $out | Out-Null
$w = $Width * 2
$h = [int]([math]::Round($w * 9 / 16 / 2) * 2)
$raw = Join-Path $env:TEMP 'litewallpaper-preview.bgra'

foreach ($name in $Names) {
    $file = if (Test-Path (Join-Path $root "shaders\$name.hlsl")) { "shaders\$name.hlsl" } else { "particles\$name.json" }
    $length = "$($Seconds + $Fade)"  # string expansion always writes "5.6", whatever the locale
    $p = Start-Process $Exe -ArgumentList '--render', $file, "`"$raw`"", $w, $h, $length, ($Fps * 2) -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Warning "$name could not be rendered ($($p.ExitCode))"; continue }
    $gif = Join-Path $out "$name.gif"
    $filter = "[0]fps=$Fps,scale=${Width}:-2:flags=lanczos,split[a][b];" +
              "[a]trim=${Fade}:$($Seconds + $Fade),setpts=PTS-STARTPTS[main];[b]trim=0:${Fade},setpts=PTS-STARTPTS[head];" +
              "[main][head]xfade=transition=fade:duration=${Fade}:offset=$($Seconds - $Fade),split[x][y];" +
              "[x]palettegen=max_colors=192:stats_mode=full[pal];[y][pal]paletteuse=dither=sierra2_4a"
    & ffmpeg -v error -y -f rawvideo -pixel_format bgra -video_size "${w}x${h}" -framerate ($Fps * 2) -i $raw -filter_complex $filter -loop 0 $gif
    if ($LASTEXITCODE) { throw "ffmpeg failed for $name" }
    "{0,-18} {1,6:N0} KB" -f $name, ((Get-Item $gif).Length / 1KB)
}
Remove-Item $raw -ErrorAction SilentlyContinue
