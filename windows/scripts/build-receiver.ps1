param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Runtime)) {
    $Runtime = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win-arm64" } else { "win-x64" }
}

$windowsRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $windowsRoot "iToPC.Receiver\iToPC.Receiver.csproj"
$virtualSourceProject = Join-Path $windowsRoot "iToPC.VirtualCamera.Source\VCamNetSampleSourceAOT.csproj"
$virtualControlProject = Join-Path $windowsRoot "iToPC.VirtualCamera.Control\iToPC.VirtualCamera.Control.csproj"
$outputRoot = Join-Path $windowsRoot "dist\iToPC-Receiver-$Runtime"
$ffplayPath = Join-Path $windowsRoot "tools\ffmpeg\ffplay.exe"
$ffmpegPath = Join-Path $windowsRoot "tools\ffmpeg\ffmpeg.exe"
$virtualSourceOutput = Join-Path $windowsRoot "build\vcam-source"
$virtualControlOutput = Join-Path $windowsRoot "build\vcam-control"
$virtualPackageOutput = Join-Path $windowsRoot "build\vcam-package"

if (-not (Test-Path -LiteralPath $ffplayPath) -or -not (Test-Path -LiteralPath $ffmpegPath)) {
    & (Join-Path $PSScriptRoot "setup-ffmpeg.ps1") -Runtime $Runtime
}

dotnet publish $virtualSourceProject `
    --configuration Release `
    --runtime $Runtime `
    --output $virtualSourceOutput `
    -p:DebugType=None `
    -p:DebugSymbols=false

dotnet publish $virtualControlProject `
    --configuration Release `
    --runtime $Runtime `
    --output $virtualControlOutput `
    -p:DebugType=None `
    -p:DebugSymbols=false

New-Item -ItemType Directory -Path $virtualPackageOutput -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $virtualSourceOutput "iToPC.VirtualCamera.Source.dll") -Destination $virtualPackageOutput -Force
Copy-Item -LiteralPath (Join-Path $virtualControlOutput "iToPC.VirtualCamera.Control.exe") -Destination $virtualPackageOutput -Force
Copy-Item -LiteralPath (Join-Path $windowsRoot "virtual-camera\install-vcam.ps1") -Destination $virtualPackageOutput -Force
Copy-Item -LiteralPath (Join-Path $windowsRoot "virtual-camera\uninstall-vcam.ps1") -Destination $virtualPackageOutput -Force
$thirdPartyLicense = Join-Path (Split-Path -Parent $windowsRoot) "THIRD_PARTY_LICENSES\VCamNetSample-MIT.txt"
if (Test-Path -LiteralPath $thirdPartyLicense) {
    Copy-Item -LiteralPath $thirdPartyLicense -Destination $virtualPackageOutput -Force
}

dotnet publish $projectPath `
    --configuration Release `
    --runtime $Runtime `
    --self-contained true `
    --output $outputRoot `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false

$toolOutput = Join-Path $outputRoot "tools\ffmpeg"
New-Item -ItemType Directory -Path $toolOutput -Force | Out-Null
Copy-Item -LiteralPath $ffplayPath -Destination (Join-Path $toolOutput "ffplay.exe") -Force
Copy-Item -LiteralPath $ffmpegPath -Destination (Join-Path $toolOutput "ffmpeg.exe") -Force

$licensePath = Join-Path $windowsRoot "tools\ffmpeg\FFMPEG-LICENSE.txt"
if (Test-Path -LiteralPath $licensePath) {
    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $toolOutput "FFMPEG-LICENSE.txt") -Force
}

$virtualToolOutput = Join-Path $outputRoot "tools\virtual-camera"
New-Item -ItemType Directory -Path $virtualToolOutput -Force | Out-Null
Get-ChildItem -LiteralPath $virtualPackageOutput -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $virtualToolOutput $_.Name) -Force
}

Write-Host "Windows receiver built: $(Join-Path $outputRoot 'iToPC.Receiver.exe')"
