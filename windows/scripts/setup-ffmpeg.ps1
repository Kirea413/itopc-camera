param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Runtime)) {
    $Runtime = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win-arm64" } else { "win-x64" }
}

$ffmpegArch = if ($Runtime -eq "win-arm64") { "winarm64" } else { "win64" }
$archiveName = "ffmpeg-master-latest-$ffmpegArch-gpl.zip"
$downloadUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$archiveName"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$targetRoot = Join-Path $windowsRoot "tools\ffmpeg"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itopc-ffmpeg-" + [guid]::NewGuid().ToString("N"))
$archivePath = Join-Path $tempRoot $archiveName
$extractRoot = Join-Path $tempRoot "expanded"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Write-Host "Downloading FFmpeg: $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot

    $ffplay = Get-ChildItem -LiteralPath $extractRoot -Filter "ffplay.exe" -File -Recurse | Select-Object -First 1
    $ffmpeg = Get-ChildItem -LiteralPath $extractRoot -Filter "ffmpeg.exe" -File -Recurse | Select-Object -First 1
    if (-not $ffplay -or -not $ffmpeg) {
        throw "The downloaded FFmpeg archive does not contain ffplay.exe and ffmpeg.exe."
    }

    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    Copy-Item -LiteralPath $ffplay.FullName -Destination (Join-Path $targetRoot "ffplay.exe") -Force
    Copy-Item -LiteralPath $ffmpeg.FullName -Destination (Join-Path $targetRoot "ffmpeg.exe") -Force

    $license = Get-ChildItem -LiteralPath $extractRoot -Filter "LICENSE.txt" -File -Recurse | Select-Object -First 1
    if ($license) {
        Copy-Item -LiteralPath $license.FullName -Destination (Join-Path $targetRoot "FFMPEG-LICENSE.txt") -Force
    }

    Write-Host "FFmpeg is ready: $targetRoot"
}
finally {
    $resolvedTempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($resolvedTempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTempRoot)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
