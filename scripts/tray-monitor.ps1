Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$runtimeRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $runtimeRoot "src\ClaudeCoworkFix.psm1"
$launcherScript = Join-Path $PSScriptRoot "claude-cowork-fix.ps1"

Import-Module $modulePath -Force

$context = New-ClaudeCoworkFixContext

function New-StatusIcon {
    param([string]$Color)

    $bitmap = New-Object System.Drawing.Bitmap(16, 16)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $brush = switch ($Color) {
        "green" { [System.Drawing.Brushes]::LimeGreen }
        "yellow" { [System.Drawing.Brushes]::Gold }
        "red" { [System.Drawing.Brushes]::OrangeRed }
        default { [System.Drawing.Brushes]::Gray }
    }

    $graphics.FillEllipse([System.Drawing.Brushes]::DarkSlateGray, 0, 0, 15, 15)
    $graphics.FillEllipse($brush, 3, 3, 9, 9)
    $graphics.Dispose()

    [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

$iconGreen = New-StatusIcon -Color "green"
$iconYellow = New-StatusIcon -Color "yellow"
$iconRed = New-StatusIcon -Color "red"

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Visible = $true
$notifyIcon.Text = "Claude Cowork Fix"

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$titleItem = New-Object System.Windows.Forms.ToolStripMenuItem
$titleItem.Text = "Claude Cowork Fix"
$titleItem.Enabled = $false
$menu.Items.Add($titleItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Text = "Status: checking..."
$statusItem.Enabled = $false
$menu.Items.Add($statusItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$startItem = New-Object System.Windows.Forms.ToolStripMenuItem
$startItem.Text = "Start service"
$startItem.Add_Click({
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherScript`" -Start" -WindowStyle Hidden
})
$menu.Items.Add($startItem) | Out-Null

$stopItem = New-Object System.Windows.Forms.ToolStripMenuItem
$stopItem.Text = "Stop service"
$stopItem.Add_Click({
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherScript`" -Stop" -WindowStyle Hidden
})
$menu.Items.Add($stopItem) | Out-Null

$updateItem = New-Object System.Windows.Forms.ToolStripMenuItem
$updateItem.Text = "Sync latest Claude binary"
$updateItem.Add_Click({
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherScript`" -Update" -WindowStyle Hidden
})
$menu.Items.Add($updateItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$logsItem = New-Object System.Windows.Forms.ToolStripMenuItem
$logsItem.Text = "Open log file"
$logsItem.Add_Click({
    if (Test-Path $context.LogPath) {
        Start-Process notepad.exe $context.LogPath
    }
})
$menu.Items.Add($logsItem) | Out-Null

$folderItem = New-Object System.Windows.Forms.ToolStripMenuItem
$folderItem.Text = "Open install folder"
$folderItem.Add_Click({
    if (Test-Path $context.RootPath) {
        Start-Process explorer.exe $context.RootPath
    }
})
$menu.Items.Add($folderItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "Exit tray monitor"
$exitItem.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($exitItem) | Out-Null

$notifyIcon.ContextMenuStrip = $menu

function Update-Status {
    $status = Get-ClaudeCoworkFixStatus -Context $context

    if ($status.IsProcessRunning -and $status.IsPipeReady) {
        $notifyIcon.Icon = $iconGreen
        $notifyIcon.Text = "Claude Cowork Fix: running"
        $statusItem.Text = "Status: running"
        $startItem.Enabled = $false
        $stopItem.Enabled = $true
    } elseif ($status.IsProcessRunning) {
        $notifyIcon.Icon = $iconYellow
        $notifyIcon.Text = "Claude Cowork Fix: starting"
        $statusItem.Text = "Status: starting"
        $startItem.Enabled = $false
        $stopItem.Enabled = $true
    } else {
        $notifyIcon.Icon = $iconRed
        $notifyIcon.Text = "Claude Cowork Fix: stopped"
        $statusItem.Text = "Status: stopped"
        $startItem.Enabled = $true
        $stopItem.Enabled = $false
    }
}

$notifyIcon.Add_DoubleClick({
    $status = Get-ClaudeCoworkFixStatus -Context $context
    if ($status.IsProcessRunning) {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherScript`" -Stop" -WindowStyle Hidden
    } else {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherScript`" -Start" -WindowStyle Hidden
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status
[System.Windows.Forms.Application]::Run()
