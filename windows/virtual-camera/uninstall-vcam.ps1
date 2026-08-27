$ErrorActionPreference = "Stop"
$targetDirectory = Join-Path $env:ProgramFiles "iToPC\VirtualCamera"
$sourceDll = Join-Path $targetDirectory "iToPC.VirtualCamera.Source.dll"
$controlExe = Join-Path $targetDirectory "iToPC.VirtualCamera.Control.exe"
$dataDirectory = Join-Path $env:ProgramData "iToPC"
$logPath = Join-Path $dataDirectory "virtual-camera-install.log"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required to remove the virtual camera."
}

New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format o)] Starting iToPC virtual camera removal."
function Write-InstallLog([string]$Message) {
    Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format o)] $Message"
}
function Invoke-CameraControl([string]$Executable, [string]$Command) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Executable $Command 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $output | ForEach-Object { Write-InstallLog $_.ToString() }
    return $exitCode
}

$frameServer = Get-Service -Name "FrameServer" -ErrorAction SilentlyContinue
$restartFrameServer = $frameServer -and $frameServer.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running

try {
    # IMFVirtualCamera.Remove needs the Frame Server to be available. Remove the
    # persistent camera first, then stop the service only for DLL cleanup.
    if (Test-Path -LiteralPath $controlExe) {
        $removeExitCode = Invoke-CameraControl $controlExe "remove"
        if ($removeExitCode -ne 0) {
            throw "Failed to remove the Windows virtual camera (control exit $removeExitCode)."
        }
        Write-InstallLog "Persistent virtual camera removed."
    }

    if ($restartFrameServer) {
        Stop-Service -Name "FrameServer" -Force -ErrorAction Stop
        (Get-Service -Name "FrameServer").WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(15))
    }

    if (Test-Path -LiteralPath $sourceDll) {
        & regsvr32.exe /s /u $sourceDll
    }

    if (Test-Path -LiteralPath $targetDirectory) {
        $resolvedProgramFiles = [System.IO.Path]::GetFullPath($env:ProgramFiles)
        $resolvedTarget = [System.IO.Path]::GetFullPath($targetDirectory)
        if (-not $resolvedTarget.StartsWith($resolvedProgramFiles, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a target outside Program Files."
        }
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    }
}
finally {
    if ($restartFrameServer) {
        Start-Service -Name "FrameServer" -ErrorAction SilentlyContinue
    }
}

Write-Host "iToPC Camera removed."
