# RubyOverlay

Ruby Overlay MCP is a transparent desktop companion widget with animated Ruby poses for Codex-style focus, motivation, and review workflows.

RubyOverlay runs locally from the files in this folder. It uses high-resolution transparent PNG frame folders under `assets/frames` and can be controlled directly from the widget menu, from `control.json`, or through the included MCP server.

## Windows

Run:

```powershell
.\Run-RubyOverlay.cmd
```

Useful examples:

```powershell
.\Run-RubyOverlay.cmd -Height 800 -State party -Rotate
.\Run-RubyOverlay.cmd -Height 800 -State biker -Left 980 -Top 80
.\Run-RubyOverlay.cmd -Height 800 -State party -Rotate -RotationIntervalMs 30000 -FrameIntervalMs 9000
.\Run-RubyOverlay.cmd -DisableUpdateCheck
.\Run-RubyOverlay.cmd -ValidateOnly
.\Install-RubyOverlayShortcut.ps1
```

Right-click the widget to change the state, auto-rotation, rotation states, frame timing, scale, always-on-top mode, create a desktop shortcut, or close it. State and rotation menus are grouped into Assistant and Cosplay submenus; rotation groups can be toggled on/off as a whole.

## macOS

The macOS runner is source-based and requires Xcode Command Line Tools:

```bash
xcode-select --install
chmod +x macos/Run-RubyOverlay.command macos/Install-RubyOverlayShortcut.command
./macos/Run-RubyOverlay.command --validate-only
./macos/Run-RubyOverlay.command --state party --height 800 --rotate
./macos/Run-RubyOverlay.command --disable-update-check
./macos/Install-RubyOverlayShortcut.command
```

The included GitHub Actions workflow validates this macOS runner on a hosted macOS runner.

## Rotation Config

`rotation.json` controls startup rotation:

```json
{
  "enabled": true,
  "intervalMs": 30000,
  "frameIntervalMs": 9000,
  "states": ["party", "belly dance", "samba", "biker", "idle"]
}
```

`intervalMs` is the delay between dataset/state changes. `frameIntervalMs` is the delay between individual images inside a dataset.

## MCP

The MCP server is `mcp/ruby_overlay_mcp.py`. It exposes tools to launch the widget, list available states, read/write `control.json`, read/write `rotation.json`, check for GitHub release/tag updates, and create desktop shortcuts.

Example stdio command:

```bash
python mcp/ruby_overlay_mcp.py
```

Use an absolute path to `mcp/ruby_overlay_mcp.py` when registering it in your MCP client.

## Ruby Command

The MCP tool `ruby` is the short command alias for launching RubyOverlay. If your MCP client supports custom slash-command aliases, map `/ruby` to the `ruby` tool. In clients that do not support custom slash commands, use a normal request such as `launch Ruby` or `call the ruby tool`; that avoids unknown-command errors.

## Version And Updates

The local version is stored in `VERSION`. Update settings and the most recent check result live in `update.json`.

RubyOverlay checks for updates once on startup, after the window opens. It compares the local version with the latest GitHub release, falling back to the newest Git tag when no release exists. When a newer version exists, the widget writes `control.json` so Ruby temporarily shows an update notice state in the live rotation. Use `-DisableUpdateCheck` on Windows or `--disable-update-check` on macOS to opt out.

The MCP tool `ruby_overlay_check_update` runs the same check on demand while Ruby is already running.

By default it looks for an `assets/frames/update` dataset. For compatibility with older installs it also recognizes `ruby-update`, then falls back to `deploy` and `party` if no update artwork is installed. The default and saved rotation lists exclude update-only states, so update artwork only appears when an update is available and the check tool applies the notice. When the installed version is current, the check removes update-only states from live and saved rotation.

## What's Included

This package contains:

- Windows launcher and WPF widget script
- macOS Swift/AppKit runner
- Python MCP server
- GitHub Actions macOS smoke workflow
- Version/update metadata and shortcut installers
- `control.json` and `rotation.json`
- high-resolution frame datasets under `assets/frames`

Frame assets are bundled locally, so the widget does not need to download images after installation.

## License

Source code, scripts, and MCP/widget implementation are licensed under the MIT License. See `LICENSE`.

Ruby artwork and animation frame assets under `assets/frames` are licensed under Creative Commons Attribution-NonCommercial 4.0 International (`CC BY-NC 4.0`). See `ASSET-LICENSE.md`.
