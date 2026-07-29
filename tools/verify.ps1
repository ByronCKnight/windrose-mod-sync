<#
    Verification matrix for WindroseSync.

    Deliberately breaks a real client install in several ways and checks the
    launcher repairs exactly what it should - and nothing else. The most important
    assertion is the LAST one: that Content/Paks (~18 GB of base game data) is
    never touched, proving the managed-scope containment holds.

    Requires the local test server (python -m http.server 8899) to be running,
    and the game to be closed.
#>
[CmdletBinding()]
param(
    [string]$GameRoot = "C:\Program Files (x86)\Steam\steamapps\common\Windrose"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $repo "launcher\publish\WindroseSync.exe"
$w64  = Join-Path $GameRoot "R5\Binaries\Win64"
$paks = Join-Path $GameRoot "R5\Content\Paks"

$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host ("  PASS  " + $name) -ForegroundColor Green; $script:pass++ }
    else     { Write-Host ("  FAIL  " + $name) -ForegroundColor Red;   $script:fail++
               if ($detail) { Write-Host ("        " + $detail) -ForegroundColor DarkGray } }
}
function Sync { & $exe --no-launch 2>&1 | Out-String }
function Get-Sha($p) { if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { "" } }

Write-Host "Windrose Mod Sync - verification" -ForegroundColor Cyan
Write-Host "================================="

# Fingerprint Paks up front: name+size for every file. Hashing 18 GB is far too
# slow, but any write by the launcher would change a size or the file count.
$paksBefore = Get-ChildItem $paks -File | ForEach-Object { $_.Name + ":" + $_.Length } | Sort-Object
Write-Host ("  (baseline: {0} pak files)" -f $paksBefore.Count) -ForegroundColor DarkGray
Write-Host ""

# Start from a known-good state.
Sync | Out-Null

# --- 1. already in sync -> no work -----------------------------------------
$out = Sync
Check "already in sync -> no downloads" ($out -match "Already in sync") $out

# --- 2. deleted mod folder -> restored --------------------------------------
$qd = Join-Path $w64 "ue4ss\Mods\QuickDiscard"
Remove-Item $qd -Recurse -Force
$out = Sync
$restored = (Test-Path (Join-Path $qd "Scripts\main.lua")) -and (Test-Path (Join-Path $qd "enabled.txt"))
Check "deleted mod folder -> restored" $restored $out

# --- 3. edited file -> overwritten ------------------------------------------
$lua = Join-Path $qd "Scripts\main.lua"
$good = Get-Sha $lua
Add-Content -Path $lua -Value "-- tampered"
$out = Sync
Check "tampered file -> restored to correct hash" ((Get-Sha $lua) -eq $good) $out

# --- 4. stray file -> removed ------------------------------------------------
$stray = Join-Path $w64 "ue4ss\Mods\Junk\evil.lua"
New-Item -ItemType Directory -Force -Path (Split-Path $stray) | Out-Null
Set-Content -Path $stray -Value "print('should not survive')"
$out = Sync
Check "stray file -> removed" (-not (Test-Path $stray)) $out

# --- 5. runtime artifacts survive -------------------------------------------
$log = Join-Path $w64 "ue4ss\UE4SS.log"
Set-Content -Path $log -Value "runtime log content"
$out = Sync
Check "runtime .log preserved (not deleted)" (Test-Path $log) $out

# --- 6. offline -> fail safe, do not launch ---------------------------------
# Players get no config file (the source is baked into the exe), so point at a
# dead port via a temporary sidecar. This also exercises the sidecar override.
$cfgPath = Join-Path $repo "launcher\publish\WindroseSync.config.json"
'{"base_url":"http://127.0.0.1:8898/"}' | Set-Content $cfgPath -NoNewline
try {
    $out  = & $exe --no-launch 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally {
    Remove-Item $cfgPath -Force -ErrorAction SilentlyContinue
}
Check "source unreachable -> fails safe (non-zero exit)" ($code -ne 0) ("exit=" + $code)
Check "source unreachable -> says game NOT started" ($out -match "NOT started") $out
Check "sidecar config overrides baked-in source" ($out -match "8898") $out

# --- 7. THE IMPORTANT ONE: Paks untouched -----------------------------------
$paksAfter = Get-ChildItem $paks -File | ForEach-Object { $_.Name + ":" + $_.Length } | Sort-Object
$paksSame = -not (Compare-Object $paksBefore $paksAfter)
Check "Content/Paks untouched (managed-scope containment)" $paksSame "pak inventory changed!"

# Leave the client in a good state.
Sync | Out-Null

Write-Host ""
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
if ($fail -gt 0) { exit 1 }
