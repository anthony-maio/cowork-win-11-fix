function New-ClaudeCoworkFixContext {
    [CmdletBinding()]
    param(
        [string]$RootPath = (Join-Path $env:LOCALAPPDATA "ClaudeCoworkFix"),
        [string]$TaskPrefix = "Claude Cowork Fix"
    )

    [pscustomobject]@{
        RootPath         = $RootPath
        ConfigPath       = Join-Path $RootPath "config.json"
        ServiceExePath   = Join-Path $RootPath "cowork-svc.exe"
        LogPath          = Join-Path $RootPath "claude-cowork-fix.log"
        LauncherTaskName = $TaskPrefix
        UpdateTaskName   = "$TaskPrefix Update Watcher"
        NamedPipePath    = "\\.\pipe\cowork-vm-service"
    }
}

function Get-DefaultClaudeCoworkFixConfig {
    [pscustomobject]@{
        ToolVersion                    = "0.1.0"
        AutoUpdate                     = $true
        SyncedClaudeVersion            = ""
        SyncedServiceHash              = ""
        LastSyncUtc                    = ""
        OriginalCoworkServiceStartType = ""
    }
}

function Get-ClaudeCoworkFixConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context
    )

    if (Test-Path $Context.ConfigPath) {
        return Get-Content $Context.ConfigPath -Raw | ConvertFrom-Json
    }

    Get-DefaultClaudeCoworkFixConfig
}

function Save-ClaudeCoworkFixConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context,

        [Parameter(Mandatory)]
        [psobject]$Config
    )

    if (-not (Test-Path $Context.RootPath)) {
        New-Item -Path $Context.RootPath -ItemType Directory -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 4 | Set-Content $Context.ConfigPath -Encoding UTF8
}

function Get-FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return ""
    }

    (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

function Sync-ClaudeCoworkServiceBinary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context,

        [Parameter(Mandatory)]
        [string]$SourceServiceExePath,

        [Parameter(Mandatory)]
        [string]$ClaudeVersion,

        [datetime]$Now = (Get-Date),

        [switch]$Force
    )

    if (-not (Test-Path $SourceServiceExePath)) {
        throw "Source service executable not found: $SourceServiceExePath"
    }

    if (-not (Test-Path $Context.RootPath)) {
        New-Item -Path $Context.RootPath -ItemType Directory -Force | Out-Null
    }

    $sourceHash = Get-FileSha256 -Path $SourceServiceExePath
    $destinationHash = Get-FileSha256 -Path $Context.ServiceExePath
    $changed = $Force.IsPresent -or ($sourceHash -ne $destinationHash)

    if ($changed) {
        $bytes = [System.IO.File]::ReadAllBytes($SourceServiceExePath)
        [System.IO.File]::WriteAllBytes($Context.ServiceExePath, $bytes)
        $destinationHash = Get-FileSha256 -Path $Context.ServiceExePath
    }

    $config = Get-ClaudeCoworkFixConfig -Context $Context
    $config.SyncedClaudeVersion = $ClaudeVersion
    $config.SyncedServiceHash = $destinationHash
    $config.LastSyncUtc = $Now.ToUniversalTime().ToString("o")
    Save-ClaudeCoworkFixConfig -Context $Context -Config $config

    [pscustomobject]@{
        Changed         = $changed
        SourceHash      = $sourceHash
        DestinationHash = $destinationHash
        ClaudeVersion   = $ClaudeVersion
        DestinationPath = $Context.ServiceExePath
    }
}

function Disable-CoworkVMServiceForFix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context
    )

    $service = Get-Service -Name "CoworkVMService" -ErrorAction SilentlyContinue
    if (-not $service) {
        return $false
    }

    $serviceStartType = ""
    if ($service.PSObject.Properties.Name -contains "StartType" -and $service.StartType) {
        $serviceStartType = [string]$service.StartType
    } else {
        $serviceCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='CoworkVMService'" -ErrorAction SilentlyContinue
        if ($serviceCim) {
            $serviceStartType = switch ([string]$serviceCim.StartMode) {
                "Auto" { "Automatic" }
                default { [string]$serviceCim.StartMode }
            }
        }
    }

    $config = Get-ClaudeCoworkFixConfig -Context $Context
    if (-not $config.OriginalCoworkServiceStartType -and $serviceStartType) {
        $config.OriginalCoworkServiceStartType = $serviceStartType
        Save-ClaudeCoworkFixConfig -Context $Context -Config $config
    }

    Set-Service -Name "CoworkVMService" -StartupType Disabled -ErrorAction SilentlyContinue
    if ([string]$service.Status -eq "Running") {
        Stop-Service -Name "CoworkVMService" -Force -ErrorAction SilentlyContinue
    }

    $true
}

function Restore-CoworkVMServiceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context
    )

    $service = Get-Service -Name "CoworkVMService" -ErrorAction SilentlyContinue
    if (-not $service) {
        return $false
    }

    $config = Get-ClaudeCoworkFixConfig -Context $Context
    $startupType = if ($config.OriginalCoworkServiceStartType) {
        $config.OriginalCoworkServiceStartType
    } else {
        "Automatic"
    }

    Set-Service -Name "CoworkVMService" -StartupType $startupType -ErrorAction SilentlyContinue
    $true
}

function Get-ClaudeDesktopInstall {
    [CmdletBinding()]
    param(
        [string]$WindowsAppsRoot = "C:\Program Files\WindowsApps"
    )

    $package = Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue |
        Where-Object { $_.InstallLocation } |
        Select-Object -First 1

    if ($package) {
        return [pscustomobject]@{
            Version        = [string]$package.Version
            InstallPath    = $package.InstallLocation
            ServiceExePath = Join-Path $package.InstallLocation "app\resources\cowork-svc.exe"
        }
    }

    $candidates = Get-ChildItem -Path $WindowsAppsRoot -Directory -Filter "Claude_*_x64__*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($candidates.Count -gt 0) {
        $candidate = $candidates[0]
        $version = if ($candidate.Name -match 'Claude_([\d.]+)_x64') {
            $Matches[1]
        } else {
            ""
        }

        return [pscustomobject]@{
            Version        = $version
            InstallPath    = $candidate.FullName
            ServiceExePath = Join-Path $candidate.FullName "app\resources\cowork-svc.exe"
        }
    }

    $null
}

function Stop-ClaudeCoworkProcesses {
    [CmdletBinding()]
    param()

    Get-Process -Name "cowork-svc" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-ClaudeCoworkService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context
    )

    if (-not (Test-Path $Context.ServiceExePath)) {
        throw "Local cowork-svc.exe not found: $($Context.ServiceExePath)"
    }

    Disable-CoworkVMServiceForFix -Context $Context | Out-Null
    Stop-ClaudeCoworkProcesses

    $process = Start-Process -FilePath $Context.ServiceExePath -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2

    if ($process.HasExited) {
        throw "cowork-svc.exe exited immediately with code $($process.ExitCode)"
    }

    [pscustomobject]@{
        ProcessId      = $process.Id
        Ready          = [bool](Test-Path $Context.NamedPipePath -ErrorAction SilentlyContinue)
        ServiceExePath = $Context.ServiceExePath
    }
}

function Write-ClaudeCoworkFixLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "OK")]
        [string]$Level = "INFO"
    )

    if (-not (Test-Path $Context.RootPath)) {
        New-Item -Path $Context.RootPath -ItemType Directory -Force | Out-Null
    }

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $Context.LogPath -Value $line -Encoding UTF8
    $line
}

function Get-ClaudeCoworkFixStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Context
    )

    $config = Get-ClaudeCoworkFixConfig -Context $Context
    $process = Get-Process -Name "cowork-svc" -ErrorAction SilentlyContinue
    $service = Get-Service -Name "CoworkVMService" -ErrorAction SilentlyContinue
    $launcherTask = Get-ScheduledTask -TaskName $Context.LauncherTaskName -ErrorAction SilentlyContinue
    $updateTask = Get-ScheduledTask -TaskName $Context.UpdateTaskName -ErrorAction SilentlyContinue
    $claude = Get-ClaudeDesktopInstall

    [pscustomobject]@{
        InstallRoot          = $Context.RootPath
        CopiedServiceExePath = $Context.ServiceExePath
        LogPath              = $Context.LogPath
        IsProcessRunning     = [bool]$process
        ProcessId            = if ($process) { $process.Id } else { $null }
        IsPipeReady          = [bool](Test-Path $Context.NamedPipePath -ErrorAction SilentlyContinue)
        WindowsServiceStatus = if ($service) { [string]$service.Status } else { "" }
        WindowsServiceMode   = if ($service -and ($service.PSObject.Properties.Name -contains "StartType")) { [string]$service.StartType } else { "" }
        LauncherTaskPresent  = [bool]$launcherTask
        UpdateTaskPresent    = [bool]$updateTask
        ClaudeVersion        = if ($claude) { $claude.Version } else { "" }
        ClaudeServiceExePath = if ($claude) { $claude.ServiceExePath } else { "" }
        SyncedClaudeVersion  = $config.SyncedClaudeVersion
        SyncedServiceHash    = $config.SyncedServiceHash
        LastSyncUtc          = $config.LastSyncUtc
        AutoUpdate           = $config.AutoUpdate
    }
}

Export-ModuleMember -Function New-ClaudeCoworkFixContext, Get-ClaudeCoworkFixConfig, Save-ClaudeCoworkFixConfig, Get-FileSha256, Sync-ClaudeCoworkServiceBinary, Disable-CoworkVMServiceForFix, Restore-CoworkVMServiceState, Get-ClaudeDesktopInstall, Stop-ClaudeCoworkProcesses, Start-ClaudeCoworkService, Write-ClaudeCoworkFixLog, Get-ClaudeCoworkFixStatus
