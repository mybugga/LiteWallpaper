# Fails if a built file carries anything that identifies the machine or person that built it:
# the builder's user and computer name, user-profile or build-agent paths, or a debug-symbols path.
#   powershell -ExecutionPolicy Bypass -File scripts\check-binary.ps1 LiteWallpaper.exe [more files]
param([Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Files)
$ErrorActionPreference = 'Stop'

$patterns = @('\Users\', '/Users/', '/home/', '.pdb', 'D:\a\', 'runneradmin', 'AppData\Local\Temp')
foreach ($name in $env:USERNAME, $env:COMPUTERNAME) {
    if ($name -and $name.Length -ge 3 -and $name -notmatch '^(runner|runneradmin|user|admin|administrator)$') { $patterns += $name }
}

$failed = $false
foreach ($file in $Files) {
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $file))
    $texts = @(
        [Text.Encoding]::GetEncoding(28591).GetString($bytes),            # 8-bit strings
        [Text.Encoding]::Unicode.GetString($bytes),                       # UTF-16 strings
        [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)  # UTF-16 at odd offsets
    )
    $hits = $patterns | Where-Object { $p = $_; $texts | Where-Object { $_.IndexOf($p, [StringComparison]::OrdinalIgnoreCase) -ge 0 } }
    if ($hits) {
        Write-Host "$file contains: $(($hits | Select-Object -Unique) -join ', ')"
        $failed = $true
    } else {
        Write-Host "$file is clean"
    }
}
if ($failed) { exit 1 }
