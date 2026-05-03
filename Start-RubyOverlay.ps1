param(
    [string]$SpritesheetPath = (Join-Path $PSScriptRoot "assets\ruby-spritesheet.png"),
    [string]$FrameRoot = (Join-Path $PSScriptRoot "assets\frames"),
    [string]$State = "idle",
    [int]$Height = 800,
    [int]$Left = 900,
    [int]$Top = 80,
    [double]$AnimationDelayMultiplier = 7.5,
    [string]$ControlPath = (Join-Path $PSScriptRoot "control.json"),
    [string]$RotationConfigPath = (Join-Path $PSScriptRoot "rotation.json"),
    [switch]$Rotate,
    [string]$RotateStates = "",
    [int]$RotationIntervalMs = 0,
    [int]$FrameIntervalMs = 9000,
    [switch]$ValidateOnly,
    [int]$CloseAfterMs = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw "RubyOverlay must run in STA mode. Use Run-RubyOverlay.cmd."
}

Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase,System.Xaml

$columns = 8
$rows = 9

$states = [ordered]@{
    "idle" = @{
        Row = 0
        Durations = @(1680, 660, 660, 840, 840, 1920)
    }
    "running-right" = @{
        Row = 1
        Durations = @(120, 120, 120, 120, 120, 120, 120, 220)
    }
    "running-left" = @{
        Row = 2
        Durations = @(120, 120, 120, 120, 120, 120, 120, 220)
    }
    "waving" = @{
        Row = 3
        Durations = @(140, 140, 140, 280)
    }
    "jumping" = @{
        Row = 4
        Durations = @(140, 140, 140, 140, 280)
    }
    "failed" = @{
        Row = 5
        Durations = @(140, 140, 140, 140, 140, 140, 140, 240)
    }
    "waiting" = @{
        Row = 6
        Durations = @(150, 150, 150, 150, 150, 260)
    }
    "running" = @{
        Row = 7
        Durations = @(120, 120, 120, 120, 120, 220)
    }
    "review" = @{
        Row = 8
        Durations = @(150, 150, 150, 150, 150, 280)
    }
}
$script:delayMultiplier = [Math]::Max(0.25, [Math]::Min(10.0, $AnimationDelayMultiplier))
$script:frameSources = @{}
$script:frameCounts = @{}
$script:timer = $null
$script:topmostItem = $null
$script:lastControlWriteTimeUtc = $null
$script:lastRotationConfigWriteTimeUtc = $null
$script:rotationEnabled = $false
$script:rotationStates = New-Object System.Collections.Generic.List[string]
$script:rotationCycleIntervalMs = 9000
$script:frameIntervalMs = [Math]::Max(500, [Math]::Min(60000, $FrameIntervalMs))
$script:rotationTimer = $null
$script:rotateItem = $null
$script:rotationStateItems = @{}
$script:rotationIntervalItems = @{}
$script:rotationCurrentItem = $null
$script:frameIntervalItems = @{}
$script:frameCurrentItem = $null
$script:rotationLogPath = Join-Path $PSScriptRoot "output\rotation.log"
$frameCache = @{}
$supportedFrameExtensions = @(".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff")

if (Test-Path -LiteralPath $FrameRoot) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $FrameRoot -Directory | Sort-Object Name)) {
        $hasFrames = @(Get-ChildItem -LiteralPath $directory.FullName -File |
            Where-Object { $supportedFrameExtensions -contains $_.Extension.ToLowerInvariant() }).Count -gt 0
        if ($hasFrames -and -not $states.Contains($directory.Name)) {
            $states[$directory.Name] = @{
                Row = $null
                Durations = @(180)
            }
        }
    }
}

function Import-RubyBitmap {
    param([string]$Path)

    $imagePath = (Resolve-Path -LiteralPath $Path).Path
    $image = New-Object System.Windows.Media.Imaging.BitmapImage
    $image.BeginInit()
    $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.UriSource = [Uri]::new($imagePath)
    $image.EndInit()
    $image.Freeze()
    return $image
}

$atlasBitmap = $null
$cellWidth = 0
$cellHeight = 0

if (Test-Path -LiteralPath $SpritesheetPath) {
    $atlasBitmap = Import-RubyBitmap -Path $SpritesheetPath

    if ($atlasBitmap.PixelWidth % $columns -ne 0 -or $atlasBitmap.PixelHeight % $rows -ne 0) {
        throw "Unexpected spritesheet size: $($atlasBitmap.PixelWidth)x$($atlasBitmap.PixelHeight). Expected an 8x9 atlas with even cell dimensions."
    }

    $cellWidth = [int]($atlasBitmap.PixelWidth / $columns)
    $cellHeight = [int]($atlasBitmap.PixelHeight / $rows)
}

foreach ($name in $states.Keys) {
    $stateFrameDir = Join-Path $FrameRoot $name
    $frameFiles = @()

    if (Test-Path -LiteralPath $stateFrameDir) {
        $frameFiles = @(Get-ChildItem -LiteralPath $stateFrameDir -File |
            Where-Object { $supportedFrameExtensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object Name)
    }

    if ($frameFiles.Count -gt 0) {
        $images = @($frameFiles | ForEach-Object { Import-RubyBitmap -Path $_.FullName })
        $maxWidth = [int](($images | Measure-Object -Property PixelWidth -Maximum).Maximum)
        $maxHeight = [int](($images | Measure-Object -Property PixelHeight -Maximum).Maximum)
        $script:frameSources[$name] = @{
            Kind = "frames"
            Frames = $images
            Width = $maxWidth
            Height = $maxHeight
        }
        $script:frameCounts[$name] = $images.Count
    } elseif ($null -ne $atlasBitmap -and $null -ne $states[$name].Row) {
        $script:frameSources[$name] = @{
            Kind = "atlas"
            Row = [int]$states[$name].Row
            Width = $cellWidth
            Height = $cellHeight
        }
        $script:frameCounts[$name] = $states[$name].Durations.Count
    }
}

$missingStates = @($states.Keys | Where-Object { -not $script:frameSources.ContainsKey($_) })
foreach ($name in $missingStates) {
    $states.Remove($name)
}

if ($script:frameSources.Count -eq 0) {
    throw "No frame source found. Provide an atlas with -SpritesheetPath or per-frame PNGs under -FrameRoot."
}

if (-not $script:frameSources.ContainsKey($State)) {
    $availableStates = @($states.Keys)
    if ($PSBoundParameters.ContainsKey("State")) {
        throw "Unknown state '$State'. Available states: $($availableStates -join ', ')."
    }
    $State = [string]$availableStates[0]
}

function Get-RubyDuration {
    param([int]$DurationMs)

    return [Math]::Max(16, [int][Math]::Round($DurationMs * $script:delayMultiplier))
}

function Get-RubyDurations {
    param([string]$FrameState)

    $baseDurations = @($states[$FrameState].Durations)
    $frameCount = [int]$script:frameCounts[$FrameState]
    $durations = New-Object System.Collections.Generic.List[int]

    for ($index = 0; $index -lt $frameCount; $index++) {
        if ($index -lt $baseDurations.Count) {
            $durations.Add([int]$baseDurations[$index])
        } else {
            $durations.Add([int]$baseDurations[$baseDurations.Count - 1])
        }
    }

    return ,$durations.ToArray()
}

function Get-RubyFrameDelayMs {
    param(
        [string]$FrameState,
        [int]$FrameIndex
    )

    if ($script:frameSources[$FrameState].Kind -eq "frames") {
        return [int]$script:frameIntervalMs
    }

    $durations = @(Get-RubyDurations -FrameState $FrameState)
    $duration = [int]$durations[$FrameIndex % $durations.Count]
    return [int](Get-RubyDuration -DurationMs $duration)
}

function Get-RubySourceSize {
    param([string]$FrameState)

    $source = $script:frameSources[$FrameState]
    return @{
        Width = [int]$source.Width
        Height = [int]$source.Height
    }
}

function Get-RubyFrame {
    param(
        [string]$FrameState,
        [int]$FrameIndex
    )

    $source = $script:frameSources[$FrameState]
    if ($source.Kind -eq "frames") {
        $count = [int]$script:frameCounts[$FrameState]
        return $source.Frames[$FrameIndex % $count]
    }

    $key = "$FrameState/$FrameIndex"
    if ($frameCache.ContainsKey($key)) {
        return $frameCache[$key]
    }

    $row = [int]$source.Row
    $rect = [System.Windows.Int32Rect]::new($FrameIndex * $cellWidth, $row * $cellHeight, $cellWidth, $cellHeight)
    $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap -ArgumentList $atlasBitmap,$rect
    $crop.Freeze()
    $frameCache[$key] = $crop
    return $crop
}

function Get-RubyVisibleStateNames {
    $visible = New-Object System.Collections.Generic.List[string]
    foreach ($name in $states.Keys) {
        if ($script:frameSources.ContainsKey($name) -and $script:frameSources[$name].Kind -eq "frames") {
            $visible.Add([string]$name)
        }
    }

    if ($visible.Count -eq 0) {
        foreach ($name in $states.Keys) {
            $visible.Add([string]$name)
        }
    }

    return [string[]]$visible.ToArray()
}

if ($ValidateOnly) {
    foreach ($name in $states.Keys) {
        $source = $script:frameSources[$name]
        $frameCount = [int]$script:frameCounts[$name]
        for ($index = 0; $index -lt $frameCount; $index++) {
            [void](Get-RubyFrame -FrameState $name -FrameIndex $index)
        }
        Write-Host "${name}: $($source.Kind), $frameCount frame(s), $($source.Width)x$($source.Height)"
    }
    Write-Host "RubyOverlay validation OK."
    exit 0
}

$script:visibleStateNames = @(Get-RubyVisibleStateNames)
$script:stateShortcutNames = @($script:visibleStateNames | Select-Object -First 9)

$window = New-Object System.Windows.Window
$window.Title = "Ruby Overlay"
$window.WindowStyle = [System.Windows.WindowStyle]::None
$window.ResizeMode = [System.Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.Left = $Left
$window.Top = $Top
$window.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight

$image = New-Object System.Windows.Controls.Image
$image.Stretch = [System.Windows.Media.Stretch]::Uniform
$image.SnapsToDevicePixels = $true
[System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, [System.Windows.Media.BitmapScalingMode]::HighQuality)
$window.Content = $image

$script:currentState = $State
$script:frameIndex = 0
$script:currentHeight = [Math]::Max(120, $Height)

function Set-RubySize {
    param([int]$NewHeight)

    $script:currentHeight = [Math]::Max(120, [Math]::Min(1600, $NewHeight))
    $sourceSize = Get-RubySourceSize -FrameState $script:currentState
    $image.Height = $script:currentHeight
    $image.Width = [Math]::Round($script:currentHeight * [int]$sourceSize.Width / [int]$sourceSize.Height)
}

function Set-RubyFrame {
    $frameCount = [int]$script:frameCounts[$script:currentState]
    if ($script:frameIndex -ge $frameCount) {
        $script:frameIndex = 0
    }
    $image.Source = Get-RubyFrame -FrameState $script:currentState -FrameIndex $script:frameIndex
}

function Set-RubyState {
    param([string]$NewState)

    if (-not $states.Contains($NewState)) {
        return
    }
    $script:currentState = $NewState
    $script:frameIndex = 0
    Set-RubySize -NewHeight $script:currentHeight
    Set-RubyFrame
    if ($null -ne $script:timer) {
        $script:timer.Interval = [TimeSpan]::FromMilliseconds((Get-RubyFrameDelayMs -FrameState $script:currentState -FrameIndex $script:frameIndex))
    }
}

function ConvertTo-RubyStateNames {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value -split "," | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            if ($null -ne $item) {
                $name = ([string]$item).Trim()
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $names.Add($name)
                }
            }
        }
        return [string[]]$names.ToArray()
    }

    $singleName = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($singleName)) {
        return @()
    }

    return @($singleName)
}

function Get-RubyDefaultRotationStates {
    $preferred = @(
        "party",
        "biker",
        "idle",
        "waiting",
        "waving",
        "review",
        "code review ready",
        "debugging",
        "deploy",
        "cheerleader",
        "gala",
        "elf",
        "halloween",
        "jumping",
        "failed",
        "playfull",
        "personal attention"
    )

    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($name in $preferred) {
        if ($states.Contains($name)) {
            $selected.Add($name)
        }
    }

    foreach ($name in $states.Keys) {
        if ($script:frameSources[$name].Kind -eq "frames" -and -not $selected.Contains($name)) {
            $selected.Add($name)
        }
    }

    return [string[]]$selected.ToArray()
}

function Format-RubyRotationInterval {
    $seconds = $script:rotationCycleIntervalMs / 1000.0
    if (($script:rotationCycleIntervalMs % 1000) -eq 0) {
        return "$([int]$seconds) seconds"
    }

    return ("{0:0.###} seconds" -f $seconds)
}

function Format-RubyFrameInterval {
    $seconds = $script:frameIntervalMs / 1000.0
    if (($script:frameIntervalMs % 1000) -eq 0) {
        return "$([int]$seconds) seconds"
    }

    return ("{0:0.###} seconds" -f $seconds)
}

function Get-RubyRotationStateArray {
    if ($null -eq $script:rotationStates) {
        return @()
    }

    if ($script:rotationStates -is [System.Collections.Generic.List[string]]) {
        return [string[]]$script:rotationStates.ToArray()
    }

    return [string[]]@($script:rotationStates)
}

function Write-RubyRotationLog {
    param([string]$Message)

    try {
        $directory = Split-Path -Parent $script:rotationLogPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        Add-Content -LiteralPath $script:rotationLogPath -Value "[$timestamp] $Message"
    } catch {
        # Logging is best-effort only.
    }
}

function Update-RubyRotationMenu {
    if ($null -ne $script:rotateItem) {
        $script:rotateItem.IsChecked = [bool]$script:rotationEnabled
        $script:rotateItem.IsEnabled = $script:rotationStates.Count -gt 0
    }

    if ($null -ne $script:rotationCurrentItem) {
        $script:rotationCurrentItem.Header = "Current: $(Format-RubyRotationInterval)"
    }

    if ($null -ne $script:frameCurrentItem) {
        $script:frameCurrentItem.Header = "Current: $(Format-RubyFrameInterval)"
    }

    foreach ($name in $script:rotationStateItems.Keys) {
        $script:rotationStateItems[$name].IsChecked = $script:rotationStates.Contains([string]$name)
    }

    foreach ($key in $script:rotationIntervalItems.Keys) {
        $script:rotationIntervalItems[$key].IsChecked = ([int]$key -eq $script:rotationCycleIntervalMs)
    }

    foreach ($key in $script:frameIntervalItems.Keys) {
        $script:frameIntervalItems[$key].IsChecked = ([int]$key -eq $script:frameIntervalMs)
    }
}

function Show-RubyRotationIntervalDialog {
    $dialog = New-Object System.Windows.Window
    $dialog.Title = "Rotation interval"
    $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dialog.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $dialog.ShowInTaskbar = $false
    $dialog.Topmost = $window.Topmost
    $dialog.Owner = $window

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(16)
    $panel.MinWidth = 260

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = "Seconds between state changes"
    $label.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [void]$panel.Children.Add($label)

    $input = New-Object System.Windows.Controls.TextBox
    $input.Text = ("{0:0.###}" -f ($script:rotationCycleIntervalMs / 1000.0))
    $input.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    [void]$panel.Children.Add($input)

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = "Allowed range: 1.5 to 60 seconds"
    $hint.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $hint.Opacity = 0.72
    [void]$panel.Children.Add($hint)

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

    $cancelButton = New-Object System.Windows.Controls.Button
    $cancelButton.Content = "Cancel"
    $cancelButton.MinWidth = 76
    $cancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $cancelButton.Add_Click({
        $dialog.DialogResult = $false
        $dialog.Close()
    })
    [void]$buttons.Children.Add($cancelButton)

    $okButton = New-Object System.Windows.Controls.Button
    $okButton.Content = "Save"
    $okButton.MinWidth = 76
    $okButton.IsDefault = $true
    $okButton.Add_Click({
        $seconds = 0.0
        $rawValue = $input.Text.Trim()
        $parsed = [double]::TryParse(
            $rawValue,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$seconds
        )

        if (-not $parsed) {
            $parsed = [double]::TryParse($rawValue, [ref]$seconds)
        }

        if (-not $parsed -or $seconds -lt 1.5 -or $seconds -gt 60) {
            [void][System.Windows.MessageBox]::Show($dialog, "Enter a number from 1.5 to 60.", "Rotation interval")
            return
        }

        Set-RubyRotationInterval -IntervalMs ([int][Math]::Round($seconds * 1000)) -Save
        $dialog.DialogResult = $true
        $dialog.Close()
    })
    [void]$buttons.Children.Add($okButton)

    [void]$panel.Children.Add($buttons)
    $dialog.Content = $panel
    $input.SelectAll()
    $input.Focus() | Out-Null
    [void]$dialog.ShowDialog()
}

function Show-RubyFrameIntervalDialog {
    $dialog = New-Object System.Windows.Window
    $dialog.Title = "Frame interval"
    $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dialog.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $dialog.ShowInTaskbar = $false
    $dialog.Topmost = $window.Topmost
    $dialog.Owner = $window

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(16)
    $panel.MinWidth = 260

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = "Seconds each pose image stays visible"
    $label.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [void]$panel.Children.Add($label)

    $input = New-Object System.Windows.Controls.TextBox
    $input.Text = ("{0:0.###}" -f ($script:frameIntervalMs / 1000.0))
    $input.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    [void]$panel.Children.Add($input)

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = "Allowed range: 0.5 to 60 seconds"
    $hint.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $hint.Opacity = 0.72
    [void]$panel.Children.Add($hint)

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

    $cancelButton = New-Object System.Windows.Controls.Button
    $cancelButton.Content = "Cancel"
    $cancelButton.MinWidth = 76
    $cancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $cancelButton.Add_Click({
        $dialog.DialogResult = $false
        $dialog.Close()
    })
    [void]$buttons.Children.Add($cancelButton)

    $okButton = New-Object System.Windows.Controls.Button
    $okButton.Content = "Save"
    $okButton.MinWidth = 76
    $okButton.IsDefault = $true
    $okButton.Add_Click({
        $seconds = 0.0
        $rawValue = $input.Text.Trim()
        $parsed = [double]::TryParse(
            $rawValue,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$seconds
        )

        if (-not $parsed) {
            $parsed = [double]::TryParse($rawValue, [ref]$seconds)
        }

        if (-not $parsed -or $seconds -lt 0.5 -or $seconds -gt 60) {
            [void][System.Windows.MessageBox]::Show($dialog, "Enter a number from 0.5 to 60.", "Frame interval")
            return
        }

        Set-RubyFrameInterval -IntervalMs ([int][Math]::Round($seconds * 1000)) -Save
        $dialog.DialogResult = $true
        $dialog.Close()
    })
    [void]$buttons.Children.Add($okButton)

    [void]$panel.Children.Add($buttons)
    $dialog.Content = $panel
    $input.SelectAll()
    $input.Focus() | Out-Null
    [void]$dialog.ShowDialog()
}

function Save-RubyRotationConfig {
    $config = [ordered]@{
        enabled = [bool]$script:rotationEnabled
        intervalMs = [int]$script:rotationCycleIntervalMs
        frameIntervalMs = [int]$script:frameIntervalMs
        states = @(Get-RubyRotationStateArray)
    }

    $directory = Split-Path -Parent $RotationConfigPath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $RotationConfigPath -Encoding UTF8
    $script:lastRotationConfigWriteTimeUtc = (Get-Item -LiteralPath $RotationConfigPath).LastWriteTimeUtc
}

function Set-RubyRotationTimerState {
    if ($null -eq $script:rotationTimer) {
        return
    }

    $script:rotationTimer.Interval = [TimeSpan]::FromMilliseconds($script:rotationCycleIntervalMs)
    if ($script:rotationEnabled -and $script:rotationStates.Count -gt 0) {
        $script:rotationTimer.Start()
    } else {
        $script:rotationTimer.Stop()
    }
}

function Set-RubyRotationStates {
    param(
        [object]$StateNames,
        [switch]$Save
    )

    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($name in @(ConvertTo-RubyStateNames -Value $StateNames)) {
        if ($states.Contains($name) -and -not $selected.Contains($name)) {
            $selected.Add($name)
        }
    }

    $script:rotationStates = $selected
    if ($script:rotationStates.Count -eq 0) {
        $script:rotationEnabled = $false
    }

    Update-RubyRotationMenu
    Set-RubyRotationTimerState
    if ($Save) {
        Save-RubyRotationConfig
    }
}

function Set-RubyRotationEnabled {
    param(
        [bool]$Enabled,
        [switch]$Save
    )

    $script:rotationEnabled = [bool]($Enabled -and $script:rotationStates.Count -gt 0)
    Write-RubyRotationLog -Message "enabled=$script:rotationEnabled states=$($script:rotationStates.Count) intervalMs=$script:rotationCycleIntervalMs frameIntervalMs=$script:frameIntervalMs current=$script:currentState"
    Update-RubyRotationMenu
    Set-RubyRotationTimerState
    if ($Save) {
        Save-RubyRotationConfig
    }
}

function Set-RubyRotationInterval {
    param(
        [int]$IntervalMs,
        [switch]$Save
    )

    $script:rotationCycleIntervalMs = [Math]::Max(1500, [Math]::Min(60000, $IntervalMs))
    Write-RubyRotationLog -Message "intervalMs=$script:rotationCycleIntervalMs"
    Update-RubyRotationMenu
    Set-RubyRotationTimerState
    if ($Save) {
        Save-RubyRotationConfig
    }
}

function Set-RubyFrameInterval {
    param(
        [int]$IntervalMs,
        [switch]$Save
    )

    $script:frameIntervalMs = [Math]::Max(500, [Math]::Min(60000, $IntervalMs))
    Write-RubyRotationLog -Message "frameIntervalMs=$script:frameIntervalMs"
    Update-RubyRotationMenu
    if ($null -ne $script:timer) {
        $script:timer.Interval = [TimeSpan]::FromMilliseconds((Get-RubyFrameDelayMs -FrameState $script:currentState -FrameIndex $script:frameIndex))
    }
    if ($Save) {
        Save-RubyRotationConfig
    }
}

function Set-RubyRotationStateIncluded {
    param(
        [string]$StateName,
        [bool]$Included
    )

    $nextStates = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:rotationStates) {
        if ($name -ne $StateName) {
            $nextStates.Add($name)
        }
    }

    if ($Included -and $states.Contains($StateName)) {
        $nextStates.Add($StateName)
    }

    Set-RubyRotationStates -StateNames $nextStates -Save
}

function Load-RubyRotationConfig {
    $enabled = $false
    $interval = $script:rotationCycleIntervalMs
    $frameInterval = $script:frameIntervalMs
    $stateNames = @(Get-RubyDefaultRotationStates)

    if (Test-Path -LiteralPath $RotationConfigPath) {
        try {
            $config = Get-Content -LiteralPath $RotationConfigPath -Raw | ConvertFrom-Json
            $enabledProperty = $config.PSObject.Properties["enabled"]
            $intervalProperty = $config.PSObject.Properties["intervalMs"]
            $frameIntervalProperty = $config.PSObject.Properties["frameIntervalMs"]
            $statesProperty = $config.PSObject.Properties["states"]

            if ($null -ne $enabledProperty) {
                $enabled = [bool]$enabledProperty.Value
            }
            if ($null -ne $intervalProperty) {
                $interval = [int]$intervalProperty.Value
            }
            if ($null -ne $frameIntervalProperty) {
                $frameInterval = [int]$frameIntervalProperty.Value
            }
            if ($null -ne $statesProperty) {
                $stateNames = @(ConvertTo-RubyStateNames -Value $statesProperty.Value)
            }
            $script:lastRotationConfigWriteTimeUtc = (Get-Item -LiteralPath $RotationConfigPath).LastWriteTimeUtc
        } catch {
            $enabled = $false
            $frameInterval = $script:frameIntervalMs
            $stateNames = @(Get-RubyDefaultRotationStates)
        }
    }

    Set-RubyRotationInterval -IntervalMs $interval
    Set-RubyFrameInterval -IntervalMs $frameInterval
    Set-RubyRotationStates -StateNames $stateNames
    Set-RubyRotationEnabled -Enabled $enabled
}

function Apply-RubyRotationConfig {
    if (-not (Test-Path -LiteralPath $RotationConfigPath)) {
        return
    }

    $item = Get-Item -LiteralPath $RotationConfigPath
    if ($script:lastRotationConfigWriteTimeUtc -ne $null -and $item.LastWriteTimeUtc -le $script:lastRotationConfigWriteTimeUtc) {
        return
    }

    Load-RubyRotationConfig
}

function Invoke-RubyRotation {
    if (-not $script:rotationEnabled -or $script:rotationStates.Count -eq 0) {
        Write-RubyRotationLog -Message "tick skipped enabled=$script:rotationEnabled states=$($script:rotationStates.Count)"
        return
    }

    $stateList = @(Get-RubyRotationStateArray)
    if ($stateList.Count -eq 0) {
        Write-RubyRotationLog -Message "tick skipped empty converted state list"
        return
    }

    $currentIndex = [Array]::IndexOf($stateList, $script:currentState)
    if ($currentIndex -lt 0) {
        $nextIndex = 0
    } else {
        $nextIndex = ($currentIndex + 1) % $stateList.Count
    }

    Write-RubyRotationLog -Message "tick current=$script:currentState next=$($stateList[$nextIndex]) count=$($stateList.Count)"
    Set-RubyState -NewState $stateList[$nextIndex]
}

function Apply-RubyControl {
    if (-not (Test-Path -LiteralPath $ControlPath)) {
        return
    }

    $item = Get-Item -LiteralPath $ControlPath
    if ($script:lastControlWriteTimeUtc -ne $null -and $item.LastWriteTimeUtc -le $script:lastControlWriteTimeUtc) {
        return
    }

    $script:lastControlWriteTimeUtc = $item.LastWriteTimeUtc

    try {
        $control = Get-Content -LiteralPath $ControlPath -Raw | ConvertFrom-Json
    } catch {
        return
    }

    if ($control.PSObject.Properties.Name -contains "state") {
        Set-RubyState -NewState ([string]$control.state)
    }

    if ($control.PSObject.Properties.Name -contains "height") {
        Set-RubySize -NewHeight ([int]$control.height)
    }

    if ($control.PSObject.Properties.Name -contains "topmost") {
        $window.Topmost = [bool]$control.topmost
        if ($null -ne $script:topmostItem) {
            $script:topmostItem.IsChecked = [bool]$control.topmost
        }
    }

    if ($control.PSObject.Properties.Name -contains "left") {
        $window.Left = [double]$control.left
    }

    if ($control.PSObject.Properties.Name -contains "top") {
        $window.Top = [double]$control.top
    }

    if ($control.PSObject.Properties.Name -contains "rotationStates") {
        Set-RubyRotationStates -StateNames $control.rotationStates
    }

    if ($control.PSObject.Properties.Name -contains "rotationIntervalMs") {
        Set-RubyRotationInterval -IntervalMs ([int]$control.rotationIntervalMs)
    }

    if ($control.PSObject.Properties.Name -contains "frameIntervalMs") {
        Set-RubyFrameInterval -IntervalMs ([int]$control.frameIntervalMs)
    }

    if ($control.PSObject.Properties.Name -contains "rotate") {
        Set-RubyRotationEnabled -Enabled ([bool]$control.rotate)
    } elseif ($control.PSObject.Properties.Name -contains "rotationEnabled") {
        Set-RubyRotationEnabled -Enabled ([bool]$control.rotationEnabled)
    }
}

Load-RubyRotationConfig
if ($PSBoundParameters.ContainsKey("RotationIntervalMs") -and $RotationIntervalMs -gt 0) {
    Set-RubyRotationInterval -IntervalMs $RotationIntervalMs
}
if ($PSBoundParameters.ContainsKey("FrameIntervalMs") -and $FrameIntervalMs -gt 0) {
    Set-RubyFrameInterval -IntervalMs $FrameIntervalMs
}
if ($PSBoundParameters.ContainsKey("RotateStates") -and -not [string]::IsNullOrWhiteSpace($RotateStates)) {
    Set-RubyRotationStates -StateNames $RotateStates
}
if ($Rotate) {
    Set-RubyRotationEnabled -Enabled $true
}

Set-RubySize -NewHeight $script:currentHeight
Set-RubyFrame

$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Add_Tick({
    $frameCount = [int]$script:frameCounts[$script:currentState]
    $script:frameIndex = ($script:frameIndex + 1) % $frameCount
    Set-RubyFrame
    $script:timer.Interval = [TimeSpan]::FromMilliseconds((Get-RubyFrameDelayMs -FrameState $script:currentState -FrameIndex $script:frameIndex))
})
$script:timer.Interval = [TimeSpan]::FromMilliseconds((Get-RubyFrameDelayMs -FrameState $script:currentState -FrameIndex $script:frameIndex))
$script:timer.Start()

$script:rotationTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:rotationTimer.Add_Tick({
    Invoke-RubyRotation
})
Set-RubyRotationTimerState

$contextMenu = New-Object System.Windows.Controls.ContextMenu

foreach ($name in $script:visibleStateNames) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = $name
    $stateName = $name
    $item.Add_Click({ Set-RubyState -NewState $stateName }.GetNewClosure())
    [void]$contextMenu.Items.Add($item)
}

[void]$contextMenu.Items.Add((New-Object System.Windows.Controls.Separator))

$script:rotateItem = New-Object System.Windows.Controls.MenuItem
$script:rotateItem.Header = "Auto rotate"
$script:rotateItem.IsCheckable = $true
$script:rotateItem.IsChecked = [bool]$script:rotationEnabled
$script:rotateItem.IsEnabled = $script:rotationStates.Count -gt 0
$script:rotateItem.Add_Click({
    Set-RubyRotationEnabled -Enabled $script:rotateItem.IsChecked -Save
})
[void]$contextMenu.Items.Add($script:rotateItem)

$rotationStatesMenu = New-Object System.Windows.Controls.MenuItem
$rotationStatesMenu.Header = "Rotation states"
foreach ($name in $script:visibleStateNames) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = $name
    $item.IsCheckable = $true
    $item.IsChecked = $script:rotationStates.Contains([string]$name)
    $stateName = $name
    $script:rotationStateItems[$stateName] = $item
    $item.Add_Click({
        param($sender, $eventArgs)
        Set-RubyRotationStateIncluded -StateName $stateName -Included $sender.IsChecked
    }.GetNewClosure())
    [void]$rotationStatesMenu.Items.Add($item)
}
[void]$contextMenu.Items.Add($rotationStatesMenu)

$rotationIntervalMenu = New-Object System.Windows.Controls.MenuItem
$rotationIntervalMenu.Header = "Rotation interval"
$script:rotationCurrentItem = New-Object System.Windows.Controls.MenuItem
$script:rotationCurrentItem.Header = "Current: $(Format-RubyRotationInterval)"
$script:rotationCurrentItem.IsEnabled = $false
[void]$rotationIntervalMenu.Items.Add($script:rotationCurrentItem)
[void]$rotationIntervalMenu.Items.Add((New-Object System.Windows.Controls.Separator))
foreach ($interval in @(5000, 9000, 15000, 30000)) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = "$([int]($interval / 1000)) seconds"
    $item.IsCheckable = $true
    $item.IsChecked = ($script:rotationCycleIntervalMs -eq $interval)
    $targetInterval = $interval
    $script:rotationIntervalItems[$targetInterval] = $item
    $item.Add_Click({ Set-RubyRotationInterval -IntervalMs $targetInterval -Save }.GetNewClosure())
    [void]$rotationIntervalMenu.Items.Add($item)
}
[void]$rotationIntervalMenu.Items.Add((New-Object System.Windows.Controls.Separator))
$customIntervalItem = New-Object System.Windows.Controls.MenuItem
$customIntervalItem.Header = "Custom..."
$customIntervalItem.Add_Click({ Show-RubyRotationIntervalDialog })
[void]$rotationIntervalMenu.Items.Add($customIntervalItem)
[void]$contextMenu.Items.Add($rotationIntervalMenu)

$frameIntervalMenu = New-Object System.Windows.Controls.MenuItem
$frameIntervalMenu.Header = "Frame interval"
$script:frameCurrentItem = New-Object System.Windows.Controls.MenuItem
$script:frameCurrentItem.Header = "Current: $(Format-RubyFrameInterval)"
$script:frameCurrentItem.IsEnabled = $false
[void]$frameIntervalMenu.Items.Add($script:frameCurrentItem)
[void]$frameIntervalMenu.Items.Add((New-Object System.Windows.Controls.Separator))
foreach ($interval in @(1500, 3000, 4500, 6000, 9000)) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = "$([double]($interval / 1000.0)) seconds"
    $item.IsCheckable = $true
    $item.IsChecked = ($script:frameIntervalMs -eq $interval)
    $targetInterval = $interval
    $script:frameIntervalItems[$targetInterval] = $item
    $item.Add_Click({ Set-RubyFrameInterval -IntervalMs $targetInterval -Save }.GetNewClosure())
    [void]$frameIntervalMenu.Items.Add($item)
}
[void]$frameIntervalMenu.Items.Add((New-Object System.Windows.Controls.Separator))
$customFrameIntervalItem = New-Object System.Windows.Controls.MenuItem
$customFrameIntervalItem.Header = "Custom..."
$customFrameIntervalItem.Add_Click({ Show-RubyFrameIntervalDialog })
[void]$frameIntervalMenu.Items.Add($customFrameIntervalItem)
[void]$contextMenu.Items.Add($frameIntervalMenu)

[void]$contextMenu.Items.Add((New-Object System.Windows.Controls.Separator))

foreach ($size in @(420, 600, 800, 1000, 1300)) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = "Height $size"
    $targetSize = $size
    $item.Add_Click({ Set-RubySize -NewHeight $targetSize }.GetNewClosure())
    [void]$contextMenu.Items.Add($item)
}

[void]$contextMenu.Items.Add((New-Object System.Windows.Controls.Separator))

$script:topmostItem = New-Object System.Windows.Controls.MenuItem
$script:topmostItem.Header = "Always on top"
$script:topmostItem.IsCheckable = $true
$script:topmostItem.IsChecked = $true
$script:topmostItem.Add_Click({
    $window.Topmost = $script:topmostItem.IsChecked
})
[void]$contextMenu.Items.Add($script:topmostItem)

$closeItem = New-Object System.Windows.Controls.MenuItem
$closeItem.Header = "Close"
$closeItem.Add_Click({ $window.Close() })
[void]$contextMenu.Items.Add($closeItem)

$image.ContextMenu = $contextMenu

if (Test-Path -LiteralPath $ControlPath) {
    $script:lastControlWriteTimeUtc = (Get-Item -LiteralPath $ControlPath).LastWriteTimeUtc
}

$controlTimer = New-Object System.Windows.Threading.DispatcherTimer
$controlTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$controlTimer.Add_Tick({
    Apply-RubyControl
})
$controlTimer.Start()

$rotationConfigTimer = New-Object System.Windows.Threading.DispatcherTimer
$rotationConfigTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$rotationConfigTimer.Add_Tick({
    Apply-RubyRotationConfig
})
$rotationConfigTimer.Start()

$image.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    try {
        $window.DragMove()
    } catch {
        # DragMove can throw if the pointer is released during startup.
    }
})

$image.Add_MouseWheel({
    param($sender, $eventArgs)
    $step = if ($eventArgs.Delta -gt 0) { 80 } else { -80 }
    Set-RubySize -NewHeight ($script:currentHeight + $step)
})

$window.Add_KeyDown({
    param($sender, $eventArgs)

    $shortcutIndex = $null
    switch ($eventArgs.Key) {
        "Escape" { $window.Close() }
        "Add" { Set-RubySize -NewHeight ($script:currentHeight + 80) }
        "OemPlus" { Set-RubySize -NewHeight ($script:currentHeight + 80) }
        "Subtract" { Set-RubySize -NewHeight ($script:currentHeight - 80) }
        "OemMinus" { Set-RubySize -NewHeight ($script:currentHeight - 80) }
        "D1" { $shortcutIndex = 0 }
        "D2" { $shortcutIndex = 1 }
        "D3" { $shortcutIndex = 2 }
        "D4" { $shortcutIndex = 3 }
        "D5" { $shortcutIndex = 4 }
        "D6" { $shortcutIndex = 5 }
        "D7" { $shortcutIndex = 6 }
        "D8" { $shortcutIndex = 7 }
        "D9" { $shortcutIndex = 8 }
    }

    if ($null -ne $shortcutIndex -and $shortcutIndex -lt $script:stateShortcutNames.Count) {
        Set-RubyState $script:stateShortcutNames[$shortcutIndex]
    }
})

if ($CloseAfterMs -gt 0) {
    $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $closeTimer.Interval = [TimeSpan]::FromMilliseconds($CloseAfterMs)
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        $window.Close()
    })
    $closeTimer.Start()
}

[void]$window.ShowDialog()
