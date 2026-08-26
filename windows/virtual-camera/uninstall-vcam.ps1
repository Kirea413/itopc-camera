$ErrorActionPreference = "Stop"
$targetDirectory = Join-Path $env:ProgramFiles "iToPC\VirtualCamera"
$sourceDll = Join-Path $targetDirectory "iToPC.VirtualCamera.Source.dll"
$controlExe = Join-Path $targetDirectory "iToPC.VirtualCamera.Control.exe"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "仮想カメラの削除には管理者権限が必要です。"
}

if (Test-Path -LiteralPath $controlExe) {
    & $controlExe remove
}
if (Test-Path -LiteralPath $sourceDll) {
    & regsvr32.exe /s /u $sourceDll
}

if (Test-Path -LiteralPath $targetDirectory) {
    $resolvedProgramFiles = [System.IO.Path]::GetFullPath($env:ProgramFiles)
    $resolvedTarget = [System.IO.Path]::GetFullPath($targetDirectory)
    if (-not $resolvedTarget.StartsWith($resolvedProgramFiles, [StringComparison]::OrdinalIgnoreCase)) {
        throw "削除対象がProgram Files外を指しています。"
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}

Write-Host "iToPC Cameraを削除しました。"
