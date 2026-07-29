<#
.SYNOPSIS
    Regenerates manifest.json for Windrose Mod Sync.

.DESCRIPTION
    Walks payload/client and payload/server, hashes every file, and writes a
    manifest the launcher uses to decide what a synced client looks like.

    The manifest must be DETERMINISTIC: running this twice on unchanged input has
    to produce an identical client_digest, otherwise every client would re-download
    the world on each publish. Paths are normalised to forward slashes and sorted
    ordinally to guarantee that.

.PARAMETER Release
    Release tag, e.g. v1.0.0. Defaults to a UTC datestamp.

.PARAMETER ClientExe / ServerExe
    The two Windrose binaries whose hashes pin this mod set to a game build.
    CampDeposit refuses to run in full mode against an unrecognised build, so the
    launcher warns when a player's game doesn't match what the manifest was built for.
    Pass empty string to skip (game_build fields become null).
#>
[CmdletBinding()]
param(
    [string]$Release = ("v" + (Get-Date).ToUniversalTime().ToString("yyyy.MM.dd.HHmm")),

    [string]$ClientExe = "C:\Program Files (x86)\Steam\steamapps\common\Windrose\R5\Binaries\Win64\Windrose-Win64-Shipping.exe",

    [string]$ServerExe = "C:\Program Files (x86)\Steam\steamapps\common\Windrose Dedicated Server\R5\Binaries\Win64\WindroseServer-Win64-Shipping.exe"
)

$ErrorActionPreference = "Stop"

$repoRoot    = Split-Path -Parent $PSScriptRoot
$payloadRoot = Join-Path $repoRoot "payload"
$manifestOut = Join-Path $repoRoot "manifest.json"

if (-not (Test-Path $payloadRoot)) {
    throw "payload/ not found under $repoRoot"
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Collect one side (client|server) as a sorted, normalised file list.
function Get-SideFiles([string]$Side) {
    $root = Join-Path $payloadRoot $Side
    if (-not (Test-Path $root)) { return @() }

    $rootFull = (Resolve-Path $root).Path
    $entries = New-Object System.Collections.ArrayList

    Get-ChildItem -Path $rootFull -Recurse -File | ForEach-Object {
        # Relative, forward-slashed path so the manifest is OS-neutral and stable.
        $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
        [void]$entries.Add([PSCustomObject]@{
            side   = $Side
            path   = $rel
            sha256 = Get-Sha256 $_.FullName
            size   = $_.Length
        })
    }

    # Ordinal sort: culture-sensitive sorting would make the digest machine-dependent.
    return @($entries | Sort-Object -Property { $_.path } )
}

# The digest is a hash over the sorted "path:sha256" lines. One value that changes
# if any file is added, removed, or altered.
function Get-Digest($Files) {
    if (-not $Files -or $Files.Count -eq 0) { return "" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $Files) { [void]$sb.Append($f.path).Append(':').Append($f.sha256).Append("`n") }
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    try   { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

Write-Host "Hashing payload..." -ForegroundColor Cyan
$clientFiles = Get-SideFiles "client"
$hostFiles   = Get-SideFiles "hostserver"
$serverFiles = Get-SideFiles "server"

if ($clientFiles.Count -eq 0) { throw "payload/client is empty - refusing to publish a manifest that would wipe every client." }

# The launcher installs client + hostserver, so the digest that decides
# "is this player in sync" has to cover both.
$installFiles = @($clientFiles) + @($hostFiles)
$clientDigest = Get-Digest $installFiles
$serverDigest = Get-Digest $serverFiles

# Pin to the game build these mods were assembled against.
$gameBuild = [ordered]@{ client_sha256 = $null; server_sha256 = $null }
if ($ClientExe -and (Test-Path $ClientExe)) { $gameBuild.client_sha256 = Get-Sha256 $ClientExe }
elseif ($ClientExe) { Write-Warning "Client exe not found, game_build.client_sha256 will be null: $ClientExe" }
if ($ServerExe -and (Test-Path $ServerExe)) { $gameBuild.server_sha256 = Get-Sha256 $ServerExe }
elseif ($ServerExe) { Write-Warning "Server exe not found, game_build.server_sha256 will be null: $ServerExe" }

$manifest = [ordered]@{
    manifest_version = 1
    release          = $Release
    generated_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    game_build       = $gameBuild
    client_digest    = $clientDigest
    server_digest    = $serverDigest
    # Only launcher-installed files are listed. payload/server is uploaded to the
    # dedicated server by hand and is never touched by the launcher.
    #
    # "target" says WHERE each file goes on the player's machine:
    #   client     -> R5\Binaries\Win64                          (game + singleplayer)
    #   hostserver -> R5\Builds\WindowsServer\R5\Binaries\Win64  (Host Game process)
    files            = @($installFiles | ForEach-Object {
        [ordered]@{ target = $_.side; path = $_.path; sha256 = $_.sha256; size = $_.size }
    })
}

$json = $manifest | ConvertTo-Json -Depth 6
# UTF8 without BOM - a BOM breaks strict JSON parsers.
[System.IO.File]::WriteAllText($manifestOut, $json, (New-Object System.Text.UTF8Encoding($false)))

# Identical files across targets (UE4SS.dll, the mod itself) are downloaded once
# and copied, so report the real transfer cost rather than the naive total.
$uniqueBytes = ($installFiles | Group-Object sha256 | ForEach-Object { $_.Group[0].size } | Measure-Object -Sum).Sum
$totalBytes  = ($installFiles | Measure-Object -Property size -Sum).Sum

Write-Host ""
Write-Host "manifest.json written" -ForegroundColor Green
Write-Host ("  release       : {0}" -f $Release)
Write-Host ("  client        : {0} files -> R5\Binaries\Win64" -f $clientFiles.Count)
Write-Host ("  hostserver    : {0} files -> R5\Builds\WindowsServer\R5\Binaries\Win64" -f $hostFiles.Count)
Write-Host ("  download      : {0:N1} MB unique ({1:N1} MB on disk after copies)" -f ($uniqueBytes / 1MB), ($totalBytes / 1MB))
Write-Host ("  client_digest : {0}" -f $clientDigest)
Write-Host ("  server files  : {0}  (uploaded to the dedicated server by hand)" -f $serverFiles.Count)
Write-Host ("  game build    : client={0}" -f $(if ($gameBuild.client_sha256) { $gameBuild.client_sha256.Substring(0, 12) } else { "<none>" }))
Write-Host ""
Write-Host "Next: commit, then attach manifest.json + payload/client to a GitHub release tagged $Release" -ForegroundColor Yellow
