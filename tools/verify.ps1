<#
    Verification matrix for WindroseSync.

    Deliberately breaks a real client install in several ways and checks the
    launcher repairs exactly what it should - and nothing else.

    Two assertions matter most:
      - Content/Paks (~18 GB of base game data) is never touched
      - the gate is the player's to set: a sync moves file contents and leaves
        enabled/disabled exactly as it found it, in both directions

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

# A mod's per-player data sits inside the managed folder and is not in the manifest,
# so the stale sweep would eat it. DockMeBaby's saved docks are the case that matters:
# deleting them would wipe a player's docks on every launch.
$dockSave = Join-Path $w64 "ue4ss\Mods\DockMeBaby\DockMeBaby.savedata.lua"
Set-Content -Path $dockSave -Value "return { }"
$out = Sync
Check "mod .savedata.lua preserved (player data survives a sync)" (Test-Path $dockSave) $out
Remove-Item $dockSave -Force -ErrorAction SilentlyContinue

# --- multi-location ----------------------------------------------------------
Check "hostserver target installed" (Test-Path (Join-Path $hsv "ue4ss\Mods\CampDepositReloaded\Scripts\main.lua")) ""
Check "hostserver has no UI mod (QuickDiscard absent)" (-not (Test-Path (Join-Path $hsv "ue4ss\Mods\QuickDiscard"))) ""

# DockMeBaby's server half has to reach whichever process holds authority, and it needs
# UEHelpers wherever it lands.
Check "DockMeBaby installed on client"     (Test-Path (Join-Path $w64 "ue4ss\Mods\DockMeBaby\Scripts\main.lua")) ""
Check "DockMeBaby installed on hostserver" (Test-Path (Join-Path $hsv "ue4ss\Mods\DockMeBaby\Scripts\main.lua")) ""
Check "hostserver has UEHelpers (DockMeBaby requires it)" (Test-Path (Join-Path $hsv "ue4ss\Mods\shared\UEHelpers\UEHelpers.lua")) ""

$hostMod = Join-Path $hsv "ue4ss\Mods\CampDepositReloaded"
Remove-Item $hostMod -Recurse -Force
$out = Sync
Check "hostserver mod deleted -> restored" (Test-Path (Join-Path $hostMod "Scripts\main.lua")) $out

# --- the gate ----------------------------------------------------------------
# The gate is persistent state the player owns, not a per-session flip. A sync must
# therefore leave it exactly as it found it - silently disabling someone's mods is as
# wrong as silently enabling them.
Check "after sync with mods off, client is VANILLA (no proxy)"     (-not (ProxyOn $w64)) "dwmapi.dll present when it should not be"
Check "after sync with mods off, hostserver is VANILLA (no proxy)" (-not (ProxyOn $hsv)) "dwmapi.dll present when it should not be"

& $exe --enable | Out-Null
Check "--enable activates client mods"     (ProxyOn $w64) ""
Check "--enable activates hostserver mods" (ProxyOn $hsv) ""

Sync | Out-Null
Check "sync PRESERVES an enabled gate"  (ProxyOn $w64) "a sync must not silently disable mods"

& $exe --disable | Out-Null
Check "--disable returns client to vanilla"     (-not (ProxyOn $w64)) ""
Check "--disable returns hostserver to vanilla" (-not (ProxyOn $hsv)) ""

Sync | Out-Null
Check "sync PRESERVES a disabled gate" (-not (ProxyOn $w64)) "a sync must not silently enable mods"

# --- the three states --------------------------------------------------------
$out = & $exe --status | Out-String
Check "--status reports DISABLED" ($out -match "INSTALLED but DISABLED") $out

& $exe --uninstall | Out-Null
Check "--uninstall removes the client mod tree"     (-not (Test-Path (Join-Path $w64 "ue4ss"))) ""
Check "--uninstall removes the hostserver mod tree" (-not (Test-Path (Join-Path $hsv "ue4ss"))) ""
Check "--uninstall leaves no proxy behind"          (-not (ProxyOn $w64)) ""
$out = & $exe --status | Out-String
Check "--status reports NOT INSTALLED" ($out -match "NOT INSTALLED") $out

& $exe --enable | Out-Null
Check "reinstall restores the mod set" (Test-Path (Join-Path $w64 "ue4ss\Mods\QuickDiscard\Scripts\main.lua")) ""
Check "reinstall re-enables the gate"  (ProxyOn $w64) ""
$out = & $exe --status | Out-String
Check "--status reports ENABLED" ($out -match "INSTALLED and ENABLED") $out
& $exe --disable | Out-Null

# --- the menu ----------------------------------------------------------------
# The menu appears only when no flag was passed, and must quit cleanly on Q - a
# redirected or piped stdin must never leave it spinning on EOF.
$out  = @("q") | & $exe | Out-String
$code = $LASTEXITCODE
Check "no-flag run shows the menu"  ($out -match "What would you like to do") $out
Check "menu quits cleanly on Q"     ($code -eq 0) ("exit=" + $code)
Check "quitting the menu changes no state" (-not (ProxyOn $w64)) ""

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
Check "source unreachable -> does not enable mods" (-not (ProxyOn $w64)) ""

# --- containment -------------------------------------------------------------
$paksAfter = Get-ChildItem $paks -File | ForEach-Object { $_.Name + ":" + $_.Length } | Sort-Object
Check "Content/Paks untouched (managed-scope containment)" (-not (Compare-Object $paksBefore $paksAfter)) "pak inventory changed!"

Sync | Out-Null

Write-Host ""
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
if ($fail -gt 0) { exit 1 }
