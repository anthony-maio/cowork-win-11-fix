$modulePath = Join-Path $PSScriptRoot "..\src\ClaudeCoworkFix.psm1"
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}

Describe "New-ClaudeCoworkFixContext" {
    It "builds the expected paths from a root folder" {
        $command = Get-Command New-ClaudeCoworkFixContext -ErrorAction SilentlyContinue
        $command | Should Not BeNullOrEmpty

        $root = Join-Path $TestDrive "install"
        $context = New-ClaudeCoworkFixContext -RootPath $root -TaskPrefix "Test Prefix"

        $context.RootPath | Should Be $root
        $context.ConfigPath | Should Be (Join-Path $root "config.json")
        $context.ServiceExePath | Should Be (Join-Path $root "cowork-svc.exe")
        $context.LogPath | Should Be (Join-Path $root "claude-cowork-fix.log")
        $context.LauncherTaskName | Should Be "Test Prefix"
        $context.UpdateTaskName | Should Be "Test Prefix Update Watcher"
        $context.NamedPipePath | Should Be "\\.\pipe\cowork-vm-service"
    }
}

Describe "Claude Cowork Fix config" {
    It "returns defaults when the config file does not exist" {
        $command = Get-Command Get-ClaudeCoworkFixConfig -ErrorAction SilentlyContinue
        $command | Should Not BeNullOrEmpty

        $context = New-ClaudeCoworkFixContext -RootPath (Join-Path $TestDrive "config-defaults")
        $config = Get-ClaudeCoworkFixConfig -Context $context

        $config.ToolVersion | Should Be "0.1.0"
        $config.AutoUpdate | Should Be $true
        $config.SyncedClaudeVersion | Should Be ""
        $config.SyncedServiceHash | Should Be ""
        $config.LastSyncUtc | Should Be ""
        $config.OriginalCoworkServiceStartType | Should Be ""
    }

    It "persists config updates to disk" {
        $command = Get-Command Save-ClaudeCoworkFixConfig -ErrorAction SilentlyContinue
        $command | Should Not BeNullOrEmpty

        $context = New-ClaudeCoworkFixContext -RootPath (Join-Path $TestDrive "config-save")
        $config = Get-ClaudeCoworkFixConfig -Context $context
        $config.SyncedClaudeVersion = "1.2.3"
        $config.SyncedServiceHash = "abc123"
        $config.AutoUpdate = $false

        Save-ClaudeCoworkFixConfig -Context $context -Config $config
        $reloaded = Get-ClaudeCoworkFixConfig -Context $context

        $reloaded.SyncedClaudeVersion | Should Be "1.2.3"
        $reloaded.SyncedServiceHash | Should Be "abc123"
        $reloaded.AutoUpdate | Should Be $false
    }
}

Describe "Sync-ClaudeCoworkServiceBinary" {
    It "copies the service binary and records sync metadata when the hash changes" {
        $command = Get-Command Sync-ClaudeCoworkServiceBinary -ErrorAction SilentlyContinue
        $command | Should Not BeNullOrEmpty

        $context = New-ClaudeCoworkFixContext -RootPath (Join-Path $TestDrive "sync-copy")
        $sourceDir = Join-Path $TestDrive "source"
        New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
        $sourcePath = Join-Path $sourceDir "cowork-svc.exe"
        [System.IO.File]::WriteAllBytes($sourcePath, [byte[]](1, 2, 3, 4, 5))

        $result = Sync-ClaudeCoworkServiceBinary `
            -Context $context `
            -SourceServiceExePath $sourcePath `
            -ClaudeVersion "4.5.6" `
            -Now ([datetime]"2026-03-28T15:16:17Z")

        $result.Changed | Should Be $true
        (Test-Path $context.ServiceExePath) | Should Be $true
        [System.IO.File]::ReadAllBytes($context.ServiceExePath).Length | Should Be 5

        $config = Get-ClaudeCoworkFixConfig -Context $context
        $config.SyncedClaudeVersion | Should Be "4.5.6"
        $config.SyncedServiceHash | Should Be $result.DestinationHash
        ([datetime]$config.LastSyncUtc).ToUniversalTime().ToString("o") | Should Be "2026-03-28T15:16:17.0000000Z"
    }

    It "skips the copy when the existing binary already matches the source hash" {
        $context = New-ClaudeCoworkFixContext -RootPath (Join-Path $TestDrive "sync-skip")
        $sourceDir = Join-Path $TestDrive "source-skip"
        New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
        $sourcePath = Join-Path $sourceDir "cowork-svc.exe"
        [System.IO.File]::WriteAllBytes($sourcePath, [byte[]](9, 8, 7, 6))

        Sync-ClaudeCoworkServiceBinary `
            -Context $context `
            -SourceServiceExePath $sourcePath `
            -ClaudeVersion "7.8.9" `
            -Now ([datetime]"2026-03-28T10:00:00Z") | Out-Null

        $result = Sync-ClaudeCoworkServiceBinary `
            -Context $context `
            -SourceServiceExePath $sourcePath `
            -ClaudeVersion "7.8.9" `
            -Now ([datetime]"2026-03-28T11:00:00Z")

        $result.Changed | Should Be $false
        $config = Get-ClaudeCoworkFixConfig -Context $context
        $config.SyncedClaudeVersion | Should Be "7.8.9"
        ([datetime]$config.LastSyncUtc).ToUniversalTime().ToString("o") | Should Be "2026-03-28T11:00:00.0000000Z"
    }
}

Describe "CoworkVMService state management" {
    It "disables the Windows service and remembers its original startup type" {
        $global:testContextForModule = New-ClaudeCoworkFixContext -RootPath (Join-Path $TestDrive "service-disable")

        InModuleScope ClaudeCoworkFix {
            Mock Get-Service {
                [pscustomobject]@{
                    Name      = "CoworkVMService"
                    Status    = "Running"
                    StartType = "Automatic"
                }
            }
            Mock Set-Service {}
            Mock Stop-Service {}

            Disable-CoworkVMServiceForFix -Context $global:testContextForModule

            Assert-MockCalled Set-Service -Times 1 -ParameterFilter {
                $Name -eq "CoworkVMService" -and $StartupType -eq "Disabled"
            }
            Assert-MockCalled Stop-Service -Times 1 -ParameterFilter {
                $Name -eq "CoworkVMService"
            }
        }

        $config = Get-ClaudeCoworkFixConfig -Context $global:testContextForModule
        $config.OriginalCoworkServiceStartType | Should Be "Automatic"
    }

    It "restores the original startup type when uninstalling" {
        $context = New-ClaudeCoworkFixContext -RootPath (Join-Path $TestDrive "service-restore")
        $config = Get-ClaudeCoworkFixConfig -Context $context
        $config.OriginalCoworkServiceStartType = "Manual"
        Save-ClaudeCoworkFixConfig -Context $context -Config $config
        $global:testContextForModule = $context

        InModuleScope ClaudeCoworkFix {
            Mock Get-Service {
                [pscustomobject]@{
                    Name      = "CoworkVMService"
                    Status    = "Stopped"
                    StartType = "Disabled"
                }
            }
            Mock Set-Service {}

            Restore-CoworkVMServiceState -Context $global:testContextForModule

            Assert-MockCalled Set-Service -Times 1 -ParameterFilter {
                $Name -eq "CoworkVMService" -and $StartupType -eq "Manual"
            }
        }
    }
}

Describe "Get-ClaudeDesktopInstall" {
    It "returns install metadata from the Appx package" {
        InModuleScope ClaudeCoworkFix {
            Mock Get-AppxPackage {
                [pscustomobject]@{
                    Name            = "Claude"
                    Version         = "9.9.9"
                    InstallLocation = "C:\Program Files\WindowsApps\Claude_9.9.9_x64__abc123"
                }
            }

            $install = Get-ClaudeDesktopInstall

            $install.Version | Should Be "9.9.9"
            $install.InstallPath | Should Be "C:\Program Files\WindowsApps\Claude_9.9.9_x64__abc123"
            $install.ServiceExePath | Should Be "C:\Program Files\WindowsApps\Claude_9.9.9_x64__abc123\app\resources\cowork-svc.exe"
        }
    }
}

Describe "Start-ClaudeCoworkService" {
    It "launches the copied service executable and reports readiness" {
        $context = New-ClaudeCoworkFixContext -RootPath (Join-Path $TestDrive "start-service")
        if (-not (Test-Path $context.RootPath)) {
            New-Item -ItemType Directory -Path $context.RootPath -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes($context.ServiceExePath, [byte[]](1, 2, 3))
        $global:testContextForModule = $context

        InModuleScope ClaudeCoworkFix {
            Mock Get-Process { $null }
            Mock Get-Service { $null }
            Mock Set-Service {}
            Mock Stop-Service {}
            Mock Stop-Process {}
            Mock Start-Process {
                [pscustomobject]@{
                    HasExited = $false
                    Id        = 4242
                }
            }

            $result = Start-ClaudeCoworkService -Context $global:testContextForModule

            $result.ProcessId | Should Be 4242
            $result.Ready | Should Be $false
            $result.ServiceExePath | Should Be $global:testContextForModule.ServiceExePath
        }
    }
}
