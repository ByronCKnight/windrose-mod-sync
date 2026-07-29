<#
    Validates that what the mod source actually SERVES matches manifest.json.

    Run this after every push. It catches the class of bug where the repo is
    correct on disk but something rewrites the bytes in transit - git line-ending
    normalisation being the obvious one, which silently mangles every text file
    and makes the launcher refuse to install.

    A green run here means players will get a working sync.
#>
[CmdletBinding()]
param(
    [string]$Owner  = "",
    [string]$Repo   = "windrose-mod-sync",
    [string]$GitRef = "main",
    [string]$BaseUrl = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repoRoot = Split-Path -Parent $PSScriptRoot

# Default to whatever the launcher was last built against.
$state = Join-Path $repoRoot "launcher\.buildconfig.json"
if (-not $Owner -and -not $BaseUrl -and (Test-Path $state)) {
    $s = Get-Content $state -Raw | ConvertFrom-Json
    $Owner = $s.Owner; $Repo = $s.Repo; $GitRef = $s.GitRef; $BaseUrl = $s.BaseUrl
}
if (-not $Owner -and -not $BaseUrl) { throw "Specify -Owner (or -BaseUrl)." }

if ($BaseUrl) { $base = $BaseUrl.TrimEnd('/') + "/" }
else          { $base = "https://raw.githubusercontent.com/$Owner/$Repo/$GitRef/" }

Write-Host "Checking published payload" -ForegroundColor Cyan
Write-Host "  source: $base"
Write-Host ""

# Compare the PUBLISHED manifest, not the local one - that's what players get.
$wc = New-Object System.Net.WebClient
$wc.Headers.Add("User-Agent", "check-published")
try {
    $manifest = $wc.DownloadString($base + "manifest.json?t=" + [DateTime]::UtcNow.Ticks) | ConvertFrom-Json
} catch {
    Write-Host "  FAIL  cannot fetch manifest.json - is the repo public and pushed?" -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkGray
    exit 1
}

Write-Host "  release: $($manifest.release)   files: $($manifest.files.Count)"
Write-Host ""

$sha = [System.Security.Cryptography.SHA256]::Create()
$bad = 0; $ok = 0

foreach ($f in $manifest.files) {
    # Each file names its install target, and the same relative path exists under
    # more than one (mods.json, mods.txt, UE4SS.dll). Fetch from the right one.
    $side = if ($f.PSObject.Properties.Name -contains 'target' -and $f.target) { $f.target } else { 'client' }
    $url = $base + "payload/" + $side + "/" + ($f.path -replace '\\', '/')
    try {
        $bytes = $wc.DownloadData($url)
    } catch {
        Write-Host ("  MISSING   {0}" -f $f.path) -ForegroundColor Red
        $bad++; continue
    }
    $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    if ($hash -ne $f.sha256.ToLowerInvariant()) {
        Write-Host ("  MANGLED   {0}  ({1} -> {2} bytes)" -f $f.path, $f.size, $bytes.Length) -ForegroundColor Red
        $bad++
    } else { $ok++ }
}
$sha.Dispose()

Write-Host ""
if ($bad -eq 0) {
    Write-Host "  All $ok files match the manifest. Players will sync correctly." -ForegroundColor Green
    exit 0
}

Write-Host "  $ok intact, $bad WRONG - the launcher will refuse to install." -ForegroundColor Red
Write-Host ""
Write-Host "  If sizes shrank, git normalised line endings. Fix with:" -ForegroundColor Yellow
Write-Host "     git add .gitattributes"
Write-Host "     git add --renormalize ."
Write-Host "     git commit -m 'Store payload byte-exact'"
Write-Host "     git push"
exit 1
