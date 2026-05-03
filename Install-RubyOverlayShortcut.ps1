param(
    [string]$Name = "Ruby Overlay",
    [string]$State = "party",
    [int]$Height = 800,
    [switch]$NoRotate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "Start-RubyOverlay.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Overlay script not found: $scriptPath"
}
$iconPath = Join-Path $PSScriptRoot "assets\ruby-icon.ico"

$desktop = [Environment]::GetFolderPath("Desktop")
if ([string]::IsNullOrWhiteSpace($desktop)) {
    $desktop = Join-Path $HOME "Desktop"
}
if (-not (Test-Path -LiteralPath $desktop)) {
    New-Item -ItemType Directory -Force -Path $desktop | Out-Null
}

$safeName = ($Name -replace '[<>:"/\\|?*]', '').Trim()
if ([string]::IsNullOrWhiteSpace($safeName)) {
    $safeName = "Ruby Overlay"
}

$overlayArguments = "-Height $Height -State `"$State`""
if (-not $NoRotate) {
    $overlayArguments += " -Rotate"
}
$powershellArguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" $overlayArguments"
$commandContent = "@echo off`r`nstart `"`" powershell.exe $powershellArguments`r`n"

try {
    $shortcutPath = Join-Path $desktop "$safeName.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = $powershellArguments
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = "Launch Ruby Overlay"
    $shortcut.WindowStyle = 7
    if (Test-Path -LiteralPath $iconPath) {
        $shortcut.IconLocation = "$iconPath,0"
    }
    $shortcut.Save()
    Write-Host "Created desktop shortcut: $shortcutPath"
} catch {
    $shortcutPath = Join-Path $desktop "$safeName.cmd"
    [System.IO.File]::WriteAllText($shortcutPath, $commandContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Created desktop command shortcut: $shortcutPath"
}
