param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadDirectory
)

$ErrorActionPreference = "Stop"
$sourceClsid = "{f74cfe1b-8b5a-4a3f-9694-7d73024d8f97}"
$targetDirectory = Join-Path $env:ProgramFiles "iToPC\VirtualCamera"
$dataDirectory = Join-Path $env:ProgramData "iToPC"
$sourceDllName = "iToPC.VirtualCamera.Source.dll"
$controlExeName = "iToPC.VirtualCamera.Control.exe"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "仮想カメラのインストールには管理者権限が必要です。"
}

if ([Environment]::OSVersion.Version.Build -lt 22000) {
    throw "iToPC仮想カメラにはWindows 11 build 22000以降が必要です。"
}

$resolvedPayload = (Resolve-Path -LiteralPath $PayloadDirectory).Path
$sourceDll = Join-Path $resolvedPayload $sourceDllName
$controlExe = Join-Path $resolvedPayload $controlExeName
if (-not (Test-Path -LiteralPath $sourceDll)) { throw "仮想カメラソースがありません: $sourceDll" }
if (-not (Test-Path -LiteralPath $controlExe)) { throw "仮想カメラ制御アプリがありません: $controlExe" }

New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null

Get-ChildItem -LiteralPath $resolvedPayload -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $targetDirectory $_.Name) -Force
}

& icacls.exe $dataDirectory /inheritance:e /grant '*S-1-5-32-545:(OI)(CI)M' '*S-1-5-19:(OI)(CI)R' '*S-1-5-18:(OI)(CI)R' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "共有フレームフォルダの権限設定に失敗しました。" }

$installedSource = Join-Path $targetDirectory $sourceDllName
& regsvr32.exe /s $installedSource
if ($LASTEXITCODE -ne 0) { throw "仮想カメラCOMソースの登録に失敗しました。" }

& (Join-Path $targetDirectory $controlExeName) create
if ($LASTEXITCODE -ne 0) {
    & regsvr32.exe /s /u $installedSource
    throw "Windowsへの仮想カメラ作成に失敗しました。"
}

Write-Host "iToPC Cameraをインストールしました。"

