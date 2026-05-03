param(
    [string]$Name = "Ruby Overlay",
    [string]$State = "party",
    [int]$Height = 800,
    [switch]$NoRotate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "Run-RubyOverlay.cmd"
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found: $launcher"
}

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

$arguments = "-Height $Height -State `"$State`""
if (-not $NoRotate) {
    $arguments += " -Rotate"
}

try {
    $shortcutPath = Join-Path $desktop "$safeName.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $launcher
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = "Launch Ruby Overlay"
    $shortcut.Save()
    Write-Host "Created desktop shortcut: $shortcutPath"
} catch {
    $shortcutPath = Join-Path $desktop "$safeName.cmd"
    $content = "@echo off`r`ncall `"$launcher`" $arguments`r`n"
    [System.IO.File]::WriteAllText($shortcutPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Created desktop command shortcut: $shortcutPath"
}
