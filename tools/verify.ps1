<#
    Verification matrix for WindroseSync.

    Deliberately breaks a real client install in several ways and checks the
    launcher repairs exactly what it should - and nothing else.

    Two assertions matter most:
      - Content/Paks (~18 GB of base game data) is never touched
      - mods are OFF unless the launcher put them on, so launching from Steam
        directly runs vanilla

    Requires the local test server (python -m http.server 8899) with a sidecar
    config pointing at it, and the game closed.
#>
[CmdletBinding()]
param(
    [string]$GameRoot = "C:\Program Files (x86)\Steam\steamapps\common\Windrose"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $repo "launcher\publish\WindroseSync.exe"
$w64  = Join-Path $GameRoot "R5\Binaries\Win64"
$hsv  = Join-Path $GameRoot "R5\Builds\WindowsServer\R5\Binaries\Win64"
$paks = Join-Path $GameRoot "R5\Content\Paks"

$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host ("  PASS  " + $name) -ForegroundColor Green; $script:pass++ }
    else     { Write-Host ("  FAIL  " + $name) -ForegroundColor Red;   $script:fail++
               if ($detail) { Write-Host ("        " + $detail) -ForegroundColor DarkGray } }
}
function Sync { & $exe --no-launch 2>&1 | Out-String }
function Get-Sha($p) { if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { "" } }
function ProxyOn($root) { Test-Path (Join-Path $root "dwmapi.dll") }

Write-Host "Windrose Mod Sync - verification" -ForegroundColor Cyan
Write-Host "================================="

# Any write to Paks would change a size or the file count. Hashing 18 GB is far
# too slow, so fingerprint name+size instead.
$paksBefore = Get-ChildItem $paks -File | ForEach-Object { $_.Name + ":" + $_.Length } | Sort-Object
Write-Host ("  (baseline: {0} pak files)" -f $paksBefore.Count) -ForegroundColor DarkGray
Write-Host ""

Sync | Out-Null

# --- sync correctness --------------------------------------------------------
$out = Sync
Check "already in sync -> no downloads" ($out -match "Already in sync") $out

$qd = Join-Path $w64 "ue4ss\Mods\QuickDiscard"
Remove-Item $qd -Recurse -Force
$out = Sync
Check "deleted mod folder -> restored" (Test-Path (Join-Path $qd "Scripts\main.lua")) $out

$lua = Join-Path $qd "Scripts\main.lua"
$good = Get-Sha $lua
Add-Content -Path $lua -Value "-- tampered"
$out = Sync
Check "tampered file -> restored to correct hash" ((Get-Sha $lua) -eq $good) $out

$stray = Join-Path $w64 "ue4ss\Mods\Junk\evil.lua"
New-Item -ItemType Directory -Force -Path (Split-Path $stray) | Out-Null
Set-Content -Path $stray -Value "print('should not survive')"
$out = Sync
Check "stray file -> removed" (-not (Test-Path $stray)) $out

$log = Join-Path $w64 "ue4ss\UE4SS.log"
Set-Content -Path $log -Value "runtime log content"
$out = Sync
Check "runtime .log preserved (not deleted)" (Test-Path $log) $out

# --- multi-location ----------------------------------------------------------
Check "hostserver target installed" (Test-Path (Join-Path $hsv "ue4ss\Mods\CampDepositReloaded\Scripts\main.lua")) ""
Check "hostserver has no UI mod (QuickDiscard absent)" (-not (Test-Path (Join-Path $hsv "ue4ss\Mods\QuickDiscard"))) ""

$hostMod = Join-Path $hsv "ue4ss\Mods\CampDepositReloaded"
Remove-Item $hostMod -Recurse -Force
$out = Sync
Check "hostserver mod deleted -> restored" (Test-Path (Join-Path $hostMod "Scripts\main.lua")) $out

# --- the gate ----------------------------------------------------------------
Check "after sync, client is VANILLA (no proxy)"     (-not (ProxyOn $w64)) "dwmapi.dll present when it should not be"
Check "after sync, hostserver is VANILLA (no proxy)" (-not (ProxyOn $hsv)) "dwmapi.dll present when it should not be"

& $exe --enable | Out-Null
Check "--enable activates client mods"     (ProxyOn $w64) ""
Check "--enable activates hostserver mods" (ProxyOn $hsv) ""

& $exe --disable | Out-Null
Check "--disable returns client to vanilla"     (-not (ProxyOn $w64)) ""
Check "--disable returns hostserver to vanilla" (-not (ProxyOn $hsv)) ""

# A crashed launcher can leave the proxy behind; the next run must clear it.
Copy-Item (Join-Path $w64 "ue4ss\proxy\dwmapi.dll") (Join-Path $w64 "dwmapi.dll") -Force
Check "(setup) stale proxy planted" (ProxyOn $w64) ""
Sync | Out-Null
Check "stale proxy from a crash -> cleared on next run" (-not (ProxyOn $w64)) ""

# --- failure handling --------------------------------------------------------
$cfgPath = Join-Path $repo "launcher\publish\WindroseSync.config.json"
$cfgOrig = if (Test-Path $cfgPath) { Get-Content $cfgPath -Raw } else { $null }
'{"base_url":"http://127.0.0.1:8898/"}' | Set-Content $cfgPath -NoNewline
try {
    $out  = & $exe --no-launch 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally {
    if ($cfgOrig) { $cfgOrig | Set-Content $cfgPath -NoNewline } else { Remove-Item $cfgPath -Force -ErrorAction SilentlyContinue }
}
Check "source unreachable -> fails safe (non-zero exit)" ($code -ne 0) ("exit=" + $code)
Check "source unreachable -> says game NOT started" ($out -match "NOT started") $out
Check "source unreachable -> leaves game vanilla" (-not (ProxyOn $w64)) ""

# --- containment -------------------------------------------------------------
$paksAfter = Get-ChildItem $paks -File | ForEach-Object { $_.Name + ":" + $_.Length } | Sort-Object
Check "Content/Paks untouched (managed-scope containment)" (-not (Compare-Object $paksBefore $paksAfter)) "pak inventory changed!"

Sync | Out-Null

Write-Host ""
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
if ($fail -gt 0) { exit 1 }
