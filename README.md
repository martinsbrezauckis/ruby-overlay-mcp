# RubyOverlay

Transparent desktop companion widget for Codex-style presentations.

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
.\Run-RubyOverlay.cmd -ValidateOnly
```

Right-click the widget to change the state, auto-rotation, rotation states, frame timing, scale, always-on-top mode, or to close it.

## macOS

The macOS runner is source-based and requires Xcode Command Line Tools:

```bash
xcode-select --install
chmod +x macos/Run-RubyOverlay.command
./macos/Run-RubyOverlay.command --validate-only
./macos/Run-RubyOverlay.command --state party --height 800 --rotate
```

The included GitHub Actions workflow validates this macOS runner on a hosted macOS runner.

## Rotation Config

`rotation.json` controls startup rotation:

```json
{
  "enabled": true,
  "intervalMs": 30000,
  "frameIntervalMs": 9000,
  "states": ["party", "biker", "idle"]
}
```

`intervalMs` is the delay between dataset/state changes. `frameIntervalMs` is the delay between individual images inside a dataset.

## MCP

The MCP server is `mcp/ruby_overlay_mcp.py`. It exposes tools to launch the widget, list available states, read/write `control.json`, and read/write `rotation.json`.

Example stdio command:

```bash
python mcp/ruby_overlay_mcp.py
```

Use an absolute path to `mcp/ruby_overlay_mcp.py` when registering it in your MCP client.

## What's Included

This package contains:

- Windows launcher and WPF widget script
- macOS Swift/AppKit runner
- Python MCP server
- GitHub Actions macOS smoke workflow
- `control.json` and `rotation.json`
- high-resolution frame datasets under `assets/frames`

Frame assets are bundled locally, so the widget does not need to download images after installation.
