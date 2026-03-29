[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Update,
    [switch]$Start,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

$runtimeRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $runtimeRoot "src\ClaudeCoworkFix.psm1"

if (-not (Test-Path $modulePath)) {
    throw "Could not find ClaudeCoworkFix.psm1 at $modulePath"
}

Import-Module $modulePath -Force

$context = New-ClaudeCoworkFixContext
$productName = "Claude Cowork Fix"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Administrator {
    param([string]$ActionName)

    if (-not (Test-IsAdministrator)) {
        throw "$ActionName requires an elevated PowerShell session. Re-run the command as Administrator."
    }
}

function Get-InstalledScriptPath {
    Join-Path $context.RootPath "scripts\claude-cowork-fix.ps1"
}

function Get-InstalledTrayScriptPath {
    Join-Path $context.RootPath "scripts\tray-monitor.ps1"
}

function Get-CurrentUserId {
    [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Sync-RuntimeAssets {
    $sourceRoot = $runtimeRoot
    $items = @(
        @{
            Source = Join-Path $sourceRoot "src\ClaudeCoworkFix.psm1"
            Target = Join-Path $context.RootPath "src\ClaudeCoworkFix.psm1"
        },
        @{
            Source = Join-Path $sourceRoot "scripts\claude-cowork-fix.ps1"
            Target = Join-Path $context.RootPath "scripts\claude-cowork-fix.ps1"
        },
        @{
            Source = Join-Path $sourceRoot "scripts\tray-monitor.ps1"
            Target = Join-Path $context.RootPath "scripts\tray-monitor.ps1"
        }
    )

    foreach ($item in $items) {
        $targetDir = Split-Path -Parent $item.Target
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        $sourceFull = [System.IO.Path]::GetFullPath($item.Source)
        $targetFull = [System.IO.Path]::GetFullPath($item.Target)
        if ($sourceFull -ieq $targetFull) {
            continue
        }

        Copy-Item -Path $item.Source -Destination $item.Target -Force
    }
}

function Register-LauncherTask {
    $scriptPath = Get-InstalledScriptPath
    $userId = Get-CurrentUserId

    Unregister-ScheduledTask -TaskName $context.LauncherTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Start"

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    $principal = New-ScheduledTaskPrincipal `
        -UserId $userId `
        -RunLevel Highest `
        -LogonType Interactive

    Register-ScheduledTask `
        -TaskName $context.LauncherTaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description "${productName}: starts the copied cowork service at sign-in." `
        -Force | Out-Null
}

function Register-UpdateTask {
    $scriptPath = Get-InstalledScriptPath
    $userId = Get-CurrentUserId

    Unregister-ScheduledTask -TaskName $context.UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Update"

    $trigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Hours 2) `
        -RepetitionDuration (New-TimeSpan -Days 365)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $principal = New-ScheduledTaskPrincipal `
        -UserId $userId `
        -RunLevel Highest `
        -LogonType Interactive

    Register-ScheduledTask `
        -TaskName $context.UpdateTaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description "${productName}: re-syncs cowork-svc.exe after Claude updates." `
        -Force | Out-Null
}

function Remove-InstalledTasks {
    Unregister-ScheduledTask -TaskName $context.LauncherTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $context.UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Sync-ServiceBinary {
    param(
        [switch]$Force,
        [switch]$RestartIfRunning
    )

    $claudeInstall = Get-ClaudeDesktopInstall
    if (-not $claudeInstall) {
        throw "Claude Desktop was not found. Install Claude Desktop first."
    }

    if (-not (Test-Path $claudeInstall.ServiceExePath)) {
        throw "cowork-svc.exe was not found at $($claudeInstall.ServiceExePath)"
    }

    $wasRunning = [bool](Get-Process -Name "cowork-svc" -ErrorAction SilentlyContinue)
    $sourceHash = Get-FileSha256 -Path $claudeInstall.ServiceExePath
    $destinationHash = Get-FileSha256 -Path $context.ServiceExePath

    if ($wasRunning -and ($Force -or ($sourceHash -ne $destinationHash))) {
        Stop-ClaudeCoworkProcesses
        Start-Sleep -Seconds 1
    }

    $syncResult = Sync-ClaudeCoworkServiceBinary `
        -Context $context `
        -SourceServiceExePath $claudeInstall.ServiceExePath `
        -ClaudeVersion $claudeInstall.Version `
        -Force:$Force

    if ($syncResult.Changed) {
        Write-ClaudeCoworkFixLog -Context $context -Level OK -Message "Synced cowork-svc.exe from Claude v$($claudeInstall.Version)." | Out-Null
    } else {
        Write-ClaudeCoworkFixLog -Context $context -Message "cowork-svc.exe is already current for Claude v$($claudeInstall.Version)." | Out-Null
    }

    if ($RestartIfRunning -and $wasRunning -and $syncResult.Changed) {
        $restartResult = Start-ClaudeCoworkService -Context $context
        Write-ClaudeCoworkFixLog -Context $context -Level OK -Message "Restarted copied cowork service (PID $($restartResult.ProcessId))." | Out-Null
    }

    [pscustomobject]@{
        ClaudeInstall = $claudeInstall
        SyncResult    = $syncResult
    }
}

function Show-StatusLine {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host ("  {0,-18} " -f "${Label}:") -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Show-StatusScreen {
    $statusObject = Get-ClaudeCoworkFixStatus -Context $context

    Write-Host ""
    Write-Host "  $productName" -ForegroundColor Cyan
    Write-Host "  ==================" -ForegroundColor DarkCyan
    Write-Host ""

    Show-StatusLine -Label "Install root" -Value $statusObject.InstallRoot -Color DarkGray
    Show-StatusLine -Label "Copied exe" -Value $(if (Test-Path $statusObject.CopiedServiceExePath) { "present" } else { "missing" }) -Color $(if (Test-Path $statusObject.CopiedServiceExePath) { "Green" } else { "Yellow" })
    Show-StatusLine -Label "Process" -Value $(if ($statusObject.IsProcessRunning) { "running (PID $($statusObject.ProcessId))" } else { "stopped" }) -Color $(if ($statusObject.IsProcessRunning) { "Green" } else { "Yellow" })
    Show-StatusLine -Label "Named pipe" -Value $(if ($statusObject.IsPipeReady) { "ready" } else { "not detected" }) -Color $(if ($statusObject.IsPipeReady) { "Green" } else { "Yellow" })
    Show-StatusLine -Label "Windows service" -Value $(if ($statusObject.WindowsServiceStatus) { "$($statusObject.WindowsServiceStatus) / $($statusObject.WindowsServiceMode)" } else { "not found" }) -Color Gray
    Show-StatusLine -Label "Claude version" -Value $(if ($statusObject.ClaudeVersion) { $statusObject.ClaudeVersion } else { "not detected" }) -Color White
    Show-StatusLine -Label "Synced version" -Value $(if ($statusObject.SyncedClaudeVersion) { $statusObject.SyncedClaudeVersion } else { "none" }) -Color White
    Show-StatusLine -Label "Auto-start task" -Value $(if ($statusObject.LauncherTaskPresent) { "installed" } else { "missing" }) -Color $(if ($statusObject.LauncherTaskPresent) { "Green" } else { "Yellow" })
    Show-StatusLine -Label "Update task" -Value $(if ($statusObject.UpdateTaskPresent) { "installed" } else { "missing" }) -Color $(if ($statusObject.UpdateTaskPresent) { "Green" } else { "Yellow" })
    Show-StatusLine -Label "Last sync" -Value $(if ($statusObject.LastSyncUtc) { $statusObject.LastSyncUtc } else { "never" }) -Color DarkGray
    Show-StatusLine -Label "Log file" -Value $statusObject.LogPath -Color DarkGray

    if ($statusObject.ClaudeVersion -and $statusObject.SyncedClaudeVersion -and ($statusObject.ClaudeVersion -ne $statusObject.SyncedClaudeVersion)) {
        Write-Host ""
        Write-Host "  A newer Claude install was detected. Run update.bat or install.bat to refresh the copied service." -ForegroundColor Yellow
    }

    Write-Host ""
}

function Invoke-InstallFlow {
    Require-Administrator -ActionName "Install"

    Sync-RuntimeAssets
    $syncInfo = Sync-ServiceBinary -Force
    Disable-CoworkVMServiceForFix -Context $context | Out-Null
    Register-LauncherTask
    Register-UpdateTask

    $startResult = Start-ClaudeCoworkService -Context $context
    Write-ClaudeCoworkFixLog -Context $context -Level OK -Message "Installed $productName and started the copied service (PID $($startResult.ProcessId))." | Out-Null

    Write-Host ""
    Write-Host "  Installation complete." -ForegroundColor Green
    Write-Host "  Claude version: $($syncInfo.ClaudeInstall.Version)" -ForegroundColor White
    Write-Host "  Copied service: $($context.ServiceExePath)" -ForegroundColor DarkGray
    Write-Host "  Auto-start task and update watcher are installed." -ForegroundColor White
    Write-Host ""
}

function Invoke-StartFlow {
    Sync-RuntimeAssets
    $null = Sync-ServiceBinary
    $result = Start-ClaudeCoworkService -Context $context
    Write-ClaudeCoworkFixLog -Context $context -Level OK -Message "Started the copied cowork service (PID $($result.ProcessId))." | Out-Null
}

function Invoke-StopFlow {
    Stop-ClaudeCoworkProcesses
    Write-ClaudeCoworkFixLog -Context $context -Message "Stopped any running copied cowork service process." | Out-Null
    Write-Host ""
    Write-Host "  Stopped any running copied cowork service process." -ForegroundColor Yellow
    Write-Host ""
}

function Invoke-UpdateFlow {
    Sync-RuntimeAssets
    $syncInfo = Sync-ServiceBinary -RestartIfRunning

    Write-Host ""
    if ($syncInfo.SyncResult.Changed) {
        Write-Host "  Updated the copied cowork service to Claude v$($syncInfo.ClaudeInstall.Version)." -ForegroundColor Green
    } else {
        Write-Host "  The copied cowork service is already current for Claude v$($syncInfo.ClaudeInstall.Version)." -ForegroundColor Gray
    }
    Write-Host ""
}

function Invoke-UninstallFlow {
    Require-Administrator -ActionName "Uninstall"

    Remove-InstalledTasks
    Stop-ClaudeCoworkProcesses
    Restore-CoworkVMServiceState -Context $context | Out-Null
    Write-ClaudeCoworkFixLog -Context $context -Message "Removed scheduled tasks and restored the original CoworkVMService startup type." | Out-Null

    Write-Host ""
    Write-Host "  Uninstall complete." -ForegroundColor Green
    Write-Host "  Scheduled tasks were removed and CoworkVMService startup mode was restored." -ForegroundColor White
    Write-Host "  Installed files remain at $($context.RootPath)." -ForegroundColor DarkGray
    Write-Host ""
}

if ($Install) {
    Invoke-InstallFlow
    exit 0
}

if ($Uninstall) {
    Invoke-UninstallFlow
    exit 0
}

if ($Status) {
    Show-StatusScreen
    exit 0
}

if ($Update) {
    Invoke-UpdateFlow
    exit 0
}

if ($Stop) {
    Invoke-StopFlow
    exit 0
}

if ($Start) {
    Invoke-StartFlow
    exit 0
}

Invoke-StartFlow
