<#
    Builds WindroseSync.exe using the C# compiler that ships with Windows.

    No .NET SDK required. Targets .NET Framework 4.8, which is preinstalled on
    Windows 10 and 11 - so players need no runtime download either, and the
    resulting exe is tens of KB rather than a ~70 MB self-contained bundle.
#>
[CmdletBinding()]
param([switch]$Run)

$ErrorActionPreference = "Stop"

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found. Is .NET Framework 4.x installed?" }

$here = $PSScriptRoot
$out  = Join-Path $here "publish"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$exe = Join-Path $out "WindroseSync.exe"
$src = Join-Path $here "WindroseSync.cs"

$refs = @(
    "System.dll"
    "System.Core.dll"
    "System.Web.Extensions.dll"   # JavaScriptSerializer
)
$refArgs = $refs | ForEach-Object { "/reference:$_" }

Write-Host "Compiling..." -ForegroundColor Cyan
& $csc /nologo /target:exe /platform:anycpu /optimize+ /warn:4 `
       "/out:$exe" $refArgs $src

if ($LASTEXITCODE -ne 0) { throw "Compilation failed (exit $LASTEXITCODE)" }

# Ship a config template alongside so the exe is usable out of the box.
$cfgPath = Join-Path $out "WindroseSync.config.json"
if (-not (Test-Path $cfgPath)) {
@'
{
    "owner": "CHANGE-ME",
    "repo": "windrose-mod-sync",
    "gitref": "main",
    "game_path": ""
}
'@ | Set-Content -Path $cfgPath -Encoding utf8
    Write-Host "Wrote config template (set \"owner\" to your GitHub account)" -ForegroundColor Yellow
}

$size = (Get-Item $exe).Length
Write-Host ("Built {0} ({1:N0} bytes)" -f $exe, $size) -ForegroundColor Green

if ($Run) {
    Write-Host ""
    & $exe --verify --no-launch
}
