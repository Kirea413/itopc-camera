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
$logPath = Join-Path $dataDirectory "virtual-camera-install.log"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required to install the virtual camera."
}

if ([Environment]::OSVersion.Version.Build -lt 22000) {
    throw "The iToPC virtual camera requires Windows 11 build 22000 or newer."
}

New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
Set-Content -LiteralPath $logPath -Value "[$(Get-Date -Format o)] Starting iToPC virtual camera installation."
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
function Copy-PayloadFile([string]$Source, [string]$Destination) {
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq 20) { throw }
            Write-InstallLog "Copy attempt $attempt failed for $(Split-Path -Leaf $Source); waiting for camera processes to release it."
            Start-Sleep -Milliseconds 500
        }
    }
}

$resolvedPayload = (Resolve-Path -LiteralPath $PayloadDirectory).Path
$sourceDll = Join-Path $resolvedPayload $sourceDllName
$controlExe = Join-Path $resolvedPayload $controlExeName
if (-not (Test-Path -LiteralPath $sourceDll)) { throw "Virtual camera source not found: $sourceDll" }
if (-not (Test-Path -LiteralPath $controlExe)) { throw "Virtual camera control app not found: $controlExe" }

$frameServer = Get-Service -Name "FrameServer" -ErrorAction SilentlyContinue
$restartFrameServer = $frameServer -and $frameServer.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running

try {
    if ($restartFrameServer) {
        Write-InstallLog "Stopping Windows Camera Frame Server so the old source DLL can be replaced."
        Stop-Service -Name "FrameServer" -Force -ErrorAction Stop
        (Get-Service -Name "FrameServer").WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(15))
    }

    $oldSource = Join-Path $targetDirectory $sourceDllName
    Write-InstallLog "Keeping the persistent virtual-camera registration while replacing its COM source."
    if (Test-Path -LiteralPath $oldSource) {
        & regsvr32.exe /s /u $oldSource
        Write-InstallLog "Old COM source unregister returned exit code $LASTEXITCODE."
    }

    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $resolvedPayload -File | ForEach-Object {
        Write-InstallLog "Copying $($_.Name)."
        Copy-PayloadFile $_.FullName (Join-Path $targetDirectory $_.Name)
    }

    & icacls.exe $dataDirectory /inheritance:e /grant '*S-1-5-32-545:(OI)(CI)M' '*S-1-5-19:(OI)(CI)R' '*S-1-5-18:(OI)(CI)R' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set permissions on the shared-frame directory (icacls exit $LASTEXITCODE)." }
    Write-InstallLog "Shared-frame permissions updated."

    $installedSource = Join-Path $targetDirectory $sourceDllName
    & regsvr32.exe /s $installedSource
    if ($LASTEXITCODE -ne 0) { throw "Failed to register the virtual camera COM source (regsvr32 exit $LASTEXITCODE)." }
    Write-InstallLog "COM source registered."

    $createExitCode = Invoke-CameraControl (Join-Path $targetDirectory $controlExeName) "create"
    if ($createExitCode -ne 0) {
        & regsvr32.exe /s /u $installedSource
        throw "Failed to create the Windows virtual camera (control exit $createExitCode)."
    }

    Write-InstallLog "iToPC Camera installed successfully."
    Write-Host "iToPC Camera installed."
}
catch {
    Write-InstallLog "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    if ($restartFrameServer) {
        try {
            Start-Service -Name "FrameServer" -ErrorAction Stop
            Write-InstallLog "Windows Camera Frame Server restarted."
        }
        catch {
            Write-InstallLog "WARNING: Failed to restart Windows Camera Frame Server: $($_.Exception.Message)"
        }
    }
}
