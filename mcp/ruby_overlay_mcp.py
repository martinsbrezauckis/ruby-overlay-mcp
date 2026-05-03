#!/usr/bin/env python
"""Minimal MCP stdio server for controlling RubyOverlay.

This intentionally avoids third-party dependencies so it can run from the
bundled/local Python install. It implements the small MCP surface Codex needs:
initialize, tools/list, and tools/call.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTROL_PATH = PROJECT_ROOT / "control.json"
DEFAULT_ROTATION_CONFIG_PATH = PROJECT_ROOT / "rotation.json"
DEFAULT_UPDATE_CONFIG_PATH = PROJECT_ROOT / "update.json"
DEFAULT_VERSION_PATH = PROJECT_ROOT / "VERSION"
DEFAULT_FRAME_ROOT = PROJECT_ROOT / "assets" / "frames"
DEFAULT_LAUNCHER = PROJECT_ROOT / ("Run-RubyOverlay.cmd" if os.name == "nt" else "macos/Run-RubyOverlay.command")
DEFAULT_REPOSITORY = "martinsbrezauckis/ruby-overlay-mcp"
DEFAULT_UPDATE_STATE = "ruby-update"
DEFAULT_UPDATE_FALLBACK_STATES = ["deploy", "party"]


def write_response(message_id: Any, result: Any) -> None:
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message_id, "result": result}) + "\n")
    sys.stdout.flush()


def write_error(message_id: Any, code: int, message: str) -> None:
    sys.stdout.write(
        json.dumps({"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}) + "\n"
    )
    sys.stdout.flush()


def read_control(control_path: Path) -> dict[str, Any]:
    return read_json_object(control_path)


def read_json_object(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError:
        return {}
    if isinstance(data, dict):
        return data
    return {}


def write_json_object(path: Path, value: dict[str, Any]) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return value


def write_control(control_path: Path, patch: dict[str, Any]) -> dict[str, Any]:
    current = read_json_object(control_path)
    current.update({key: value for key, value in patch.items() if value is not None})
    control_path.parent.mkdir(parents=True, exist_ok=True)
    control_path.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return current


def write_rotation_config(rotation_config_path: Path, patch: dict[str, Any]) -> dict[str, Any]:
    current = read_json_object(rotation_config_path)
    if not current:
        current = {"enabled": False, "intervalMs": 9000, "frameIntervalMs": 9000, "states": []}
    current.update({key: value for key, value in patch.items() if value is not None})
    rotation_config_path.parent.mkdir(parents=True, exist_ok=True)
    rotation_config_path.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return current


def list_states(frame_root: Path) -> list[str]:
    states: list[str] = []
    if frame_root.exists():
        for child in sorted(frame_root.iterdir(), key=lambda item: item.name.lower()):
            if not child.is_dir() or child.name in states:
                continue
            has_frames = any(
                path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"}
                for path in child.iterdir()
            )
            if has_frames:
                states.append(child.name)
    return states


def read_current_version(version_path: Path = DEFAULT_VERSION_PATH) -> str:
    if not version_path.exists():
        return "0.0.0"
    version = version_path.read_text(encoding="utf-8-sig").strip()
    return version or "0.0.0"


def version_parts(version: str) -> tuple[int, ...]:
    raw = version.strip()
    if raw.lower().startswith("v"):
        raw = raw[1:]
    raw = raw.split("+", 1)[0].split("-", 1)[0]
    parts = []
    for segment in raw.split("."):
        match = re.match(r"(\d+)", segment)
        parts.append(int(match.group(1)) if match else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def is_newer_version(latest_version: str, current_version: str) -> bool:
    return version_parts(latest_version) > version_parts(current_version)


def fetch_latest_release(repository: str) -> dict[str, Any]:
    url = f"https://api.github.com/repos/{repository}/releases/latest"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": f"RubyOverlay/{read_current_version()}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=12) as response:
        return json.loads(response.read().decode("utf-8"))


def check_for_update(
    repository: str,
    current_version: str,
    fetch_latest_release=fetch_latest_release,
) -> dict[str, Any]:
    checked_at = _datetime.datetime.now(_datetime.UTC).replace(microsecond=0).isoformat()
    try:
        release = fetch_latest_release(repository)
    except urllib.error.HTTPError as exc:
        return {
            "checkedAt": checked_at,
            "currentVersion": current_version,
            "error": f"GitHub release check failed: HTTP {exc.code}",
            "latestVersion": None,
            "releaseUrl": None,
            "repository": repository,
            "updateAvailable": False,
        }
    except Exception as exc:
        return {
            "checkedAt": checked_at,
            "currentVersion": current_version,
            "error": f"GitHub release check failed: {exc}",
            "latestVersion": None,
            "releaseUrl": None,
            "repository": repository,
            "updateAvailable": False,
        }

    latest_version = str(release.get("tag_name") or release.get("name") or "").strip()
    if not latest_version:
        return {
            "checkedAt": checked_at,
            "currentVersion": current_version,
            "error": "Latest release did not include a tag_name.",
            "latestVersion": None,
            "releaseUrl": release.get("html_url"),
            "repository": repository,
            "updateAvailable": False,
        }

    return {
        "checkedAt": checked_at,
        "currentVersion": current_version,
        "latestVersion": latest_version,
        "releaseName": release.get("name"),
        "releaseUrl": release.get("html_url"),
        "repository": repository,
        "updateAvailable": is_newer_version(latest_version, current_version),
    }


def updated_update_config(config: dict[str, Any], result: dict[str, Any]) -> dict[str, Any]:
    updated = dict(config)
    if "repository" not in updated and result.get("repository"):
        updated["repository"] = result["repository"]
    updated["lastCheck"] = result
    return updated


def select_update_notice_states(
    available_states: list[str],
    current_rotation_states: list[str],
    update_state: str,
    fallback_states: list[str],
) -> list[str]:
    available = set(available_states)
    notice_state = None
    for candidate in [update_state, *fallback_states]:
        if candidate in available:
            notice_state = candidate
            break

    if notice_state is None:
        return [state for state in current_rotation_states if state in available]

    selected = [notice_state]
    for state in current_rotation_states:
        if state in available and state not in selected:
            selected.append(state)
    return selected


def text_result(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}]}


def validate_state_names(state_names: list[str], available_states: list[str]) -> None:
    unknown = [name for name in state_names if name not in available_states]
    if unknown:
        raise ValueError(f"Unknown RubyOverlay state(s): {', '.join(unknown)}.")


def is_windows_launcher(launcher: Path) -> bool:
    return launcher.suffix.lower() in {".cmd", ".bat", ".ps1"}


def launch_command_base(launcher: Path) -> list[str]:
    if is_windows_launcher(launcher):
        return [str(launcher)]
    if launcher.suffix.lower() == ".command":
        return ["/bin/zsh", str(launcher)]
    return [str(launcher)]


def add_launch_arg(command: list[str], launcher: Path, windows_name: str, posix_name: str, value: Any = None) -> None:
    command.append(windows_name if is_windows_launcher(launcher) else posix_name)
    if value is not None:
        command.append(str(value))


def create_desktop_shortcut(
    project_root: Path,
    launcher: Path,
    name: str = "Ruby Overlay",
    state: str = "party",
    height: int = 800,
    rotate: bool = True,
) -> Path:
    desktop = Path.home() / "Desktop"
    desktop.mkdir(parents=True, exist_ok=True)
    safe_name = "".join(ch for ch in name if ch not in '<>:"/\\|?*').strip() or "Ruby Overlay"

    if os.name == "nt":
        shortcut_path = desktop / f"{safe_name}.cmd"
        arguments = f'-Height {int(height)} -State "{state}"'
        if rotate:
            arguments += " -Rotate"
        shortcut_path.write_text(
            f'@echo off\r\ncall "{launcher}" {arguments}\r\n',
            encoding="utf-8",
        )
        return shortcut_path

    shortcut_path = desktop / f"{safe_name}.command"
    arguments = f'--height {int(height)} --state "{state}"'
    if rotate:
        arguments += " --rotate"
    shortcut_path.write_text(
        "#!/bin/zsh\n"
        "set -e\n"
        f'cd "{project_root}"\n'
        f'exec "{launcher}" {arguments}\n',
        encoding="utf-8",
    )
    shortcut_path.chmod(0o755)
    return shortcut_path


def launch_arguments_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "state": {"type": "string", "description": "Initial RubyOverlay state/emotion name."},
            "height": {"type": "integer", "minimum": 120, "maximum": 1600},
            "left": {"type": "number"},
            "top": {"type": "number"},
            "animation_delay_multiplier": {"type": "number", "minimum": 0.25, "maximum": 10},
            "rotate": {"type": "boolean"},
            "rotation_states": {"type": "array", "items": {"type": "string"}},
            "rotation_interval_ms": {"type": "integer", "minimum": 1500, "maximum": 60000},
            "frame_interval_ms": {"type": "integer", "minimum": 500, "maximum": 60000},
        },
        "additionalProperties": False,
    }


def tool_schemas() -> list[dict[str, Any]]:
    return [
        {
            "name": "ruby",
            "description": "Launch RubyOverlay. This is the short MCP command alias for user phrases like /ruby or launch Ruby.",
            "inputSchema": launch_arguments_schema(),
        },
        {
            "name": "ruby_overlay_list_states",
            "description": "List RubyOverlay states/emotions available from high-resolution frame folders.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        {
            "name": "ruby_overlay_get_control",
            "description": "Read the current RubyOverlay control.json state.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        {
            "name": "ruby_overlay_get_rotation",
            "description": "Read the persistent RubyOverlay rotation.json configuration.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        {
            "name": "ruby_overlay_check_update",
            "description": "Check GitHub releases for a newer RubyOverlay version and optionally show an update-only state in the live rotation.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "repository": {
                        "type": "string",
                        "description": "GitHub repository in owner/name form.",
                    },
                    "current_version": {
                        "type": "string",
                        "description": "Override the local VERSION file for this check.",
                    },
                    "apply_notice": {
                        "type": "boolean",
                        "description": "When true, update control.json so Ruby shows an update notice state if a newer release exists.",
                    },
                    "update_state": {
                        "type": "string",
                        "description": "Preferred state folder to show only when an update is available.",
                    },
                    "fallback_states": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Fallback states to use when update_state images are not installed.",
                    },
                },
                "additionalProperties": False,
            },
        },
        {
            "name": "ruby_overlay_set_rotation",
            "description": "Persistently set RubyOverlay auto-rotation enabled flag, state list, dataset interval, or frame interval.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "enabled": {"type": "boolean", "description": "Whether Auto rotate should be on."},
                    "states": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "RubyOverlay states to cycle, in order.",
                    },
                    "interval_ms": {"type": "integer", "minimum": 1500, "maximum": 60000},
                    "frame_interval_ms": {"type": "integer", "minimum": 500, "maximum": 60000},
                },
                "additionalProperties": False,
            },
        },
        {
            "name": "ruby_overlay_set_control",
            "description": "Set RubyOverlay state, display height, window position, topmost flag, or live rotation controls.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "state": {"type": "string", "description": "RubyOverlay state/emotion name."},
                    "height": {"type": "integer", "minimum": 120, "maximum": 1600},
                    "left": {"type": "number", "description": "Window left coordinate in desktop pixels."},
                    "top": {"type": "number", "description": "Window top coordinate in desktop pixels."},
                    "topmost": {"type": "boolean", "description": "Whether the overlay should stay above other windows."},
                    "rotate": {"type": "boolean", "description": "Whether Auto rotate should be on for the running widget."},
                    "rotation_states": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Live rotation states to cycle, in order.",
                    },
                    "rotation_interval_ms": {"type": "integer", "minimum": 1500, "maximum": 60000},
                    "frame_interval_ms": {"type": "integer", "minimum": 500, "maximum": 60000},
                },
                "additionalProperties": False,
            },
        },
        {
            "name": "ruby_overlay_launch",
            "description": "Launch the RubyOverlay widget as a detached local window.",
            "inputSchema": launch_arguments_schema(),
        },
        {
            "name": "ruby_overlay_create_shortcut",
            "description": "Create a desktop shortcut that launches RubyOverlay directly.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Shortcut file name without extension."},
                    "state": {"type": "string", "description": "Initial RubyOverlay state/emotion name."},
                    "height": {"type": "integer", "minimum": 120, "maximum": 1600},
                    "rotate": {"type": "boolean"},
                },
                "additionalProperties": False,
            },
        },
    ]


class RubyOverlayServer:
    def __init__(self, control_path: Path, rotation_config_path: Path, frame_root: Path, launcher: Path) -> None:
        self.control_path = control_path
        self.rotation_config_path = rotation_config_path
        self.frame_root = frame_root
        self.launcher = launcher

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        available_states = list_states(self.frame_root)

        if name == "ruby_overlay_list_states":
            return text_result(json.dumps({"states": available_states}, indent=2))

        if name == "ruby_overlay_get_control":
            return text_result(json.dumps(read_control(self.control_path), indent=2, sort_keys=True))

        if name == "ruby_overlay_get_rotation":
            return text_result(json.dumps(read_json_object(self.rotation_config_path), indent=2, sort_keys=True))

        if name == "ruby_overlay_check_update":
            update_config = read_json_object(DEFAULT_UPDATE_CONFIG_PATH)
            repository = arguments.get("repository") or update_config.get("repository") or DEFAULT_REPOSITORY
            current_version = arguments.get("current_version") or read_current_version()
            result = check_for_update(str(repository), str(current_version))
            write_json_object(DEFAULT_UPDATE_CONFIG_PATH, updated_update_config(update_config, result))

            if result["updateAvailable"] and arguments.get("apply_notice", True):
                update_state = str(arguments.get("update_state") or update_config.get("updateState") or DEFAULT_UPDATE_STATE)
                fallback_states = arguments.get("fallback_states") or update_config.get("fallbackStates") or DEFAULT_UPDATE_FALLBACK_STATES
                if not isinstance(fallback_states, list) or not all(isinstance(item, str) for item in fallback_states):
                    raise ValueError("fallback_states must be an array of strings.")
                rotation = read_json_object(self.rotation_config_path)
                current_rotation_states = rotation.get("states", [])
                if not isinstance(current_rotation_states, list):
                    current_rotation_states = []
                notice_states = select_update_notice_states(
                    available_states,
                    [str(state) for state in current_rotation_states],
                    update_state,
                    fallback_states,
                )
                if notice_states:
                    write_control(
                        self.control_path,
                        {
                            "state": notice_states[0],
                            "rotate": True,
                            "rotationStates": notice_states,
                            "updateAvailable": True,
                            "latestVersion": result["latestVersion"],
                            "releaseUrl": result["releaseUrl"],
                        },
                    )
                    result["noticeStates"] = notice_states

            return text_result(json.dumps(result, indent=2, sort_keys=True))

        if name == "ruby_overlay_set_rotation":
            states_arg = arguments.get("states")
            if states_arg is not None:
                if not isinstance(states_arg, list) or not all(isinstance(item, str) for item in states_arg):
                    raise ValueError("states must be an array of strings.")
                validate_state_names(states_arg, available_states)
            interval_ms = arguments.get("interval_ms")
            frame_interval_ms = arguments.get("frame_interval_ms")
            patch = {
                "enabled": arguments.get("enabled"),
                "states": states_arg,
                "intervalMs": int(interval_ms) if interval_ms is not None else None,
                "frameIntervalMs": int(frame_interval_ms) if frame_interval_ms is not None else None,
            }
            current = write_rotation_config(self.rotation_config_path, patch)
            return text_result("RubyOverlay rotation config updated:\n" + json.dumps(current, indent=2, sort_keys=True))

        if name == "ruby_overlay_set_control":
            state = arguments.get("state")
            if state is not None and state not in available_states:
                raise ValueError(f"Unknown RubyOverlay state '{state}'.")
            rotation_states = arguments.get("rotation_states")
            if rotation_states is not None:
                if not isinstance(rotation_states, list) or not all(isinstance(item, str) for item in rotation_states):
                    raise ValueError("rotation_states must be an array of strings.")
                validate_state_names(rotation_states, available_states)
            rotation_interval_ms = arguments.get("rotation_interval_ms")
            frame_interval_ms = arguments.get("frame_interval_ms")
            patch = {
                "state": state,
                "height": arguments.get("height"),
                "left": arguments.get("left"),
                "top": arguments.get("top"),
                "topmost": arguments.get("topmost"),
                "rotate": arguments.get("rotate"),
                "rotationStates": rotation_states,
                "rotationIntervalMs": int(rotation_interval_ms) if rotation_interval_ms is not None else None,
                "frameIntervalMs": int(frame_interval_ms) if frame_interval_ms is not None else None,
            }
            current = write_control(self.control_path, patch)
            return text_result("RubyOverlay control updated:\n" + json.dumps(current, indent=2, sort_keys=True))

        if name in {"ruby_overlay_launch", "ruby"}:
            if not self.launcher.exists():
                raise FileNotFoundError(f"Launcher not found: {self.launcher}")
            command = launch_command_base(self.launcher)
            state = arguments.get("state")
            if state is not None:
                if state not in available_states:
                    raise ValueError(f"Unknown RubyOverlay state '{state}'.")
                add_launch_arg(command, self.launcher, "-State", "--state", state)
            if arguments.get("height") is not None:
                add_launch_arg(command, self.launcher, "-Height", "--height", int(arguments["height"]))
            if arguments.get("left") is not None:
                add_launch_arg(command, self.launcher, "-Left", "--left", arguments["left"])
            if arguments.get("top") is not None:
                add_launch_arg(command, self.launcher, "-Top", "--top", arguments["top"])
            if arguments.get("animation_delay_multiplier") is not None:
                add_launch_arg(
                    command,
                    self.launcher,
                    "-AnimationDelayMultiplier",
                    "--animation-delay-multiplier",
                    arguments["animation_delay_multiplier"],
                )
            rotation_states = arguments.get("rotation_states")
            if rotation_states is not None:
                if not isinstance(rotation_states, list) or not all(isinstance(item, str) for item in rotation_states):
                    raise ValueError("rotation_states must be an array of strings.")
                validate_state_names(rotation_states, available_states)
                add_launch_arg(command, self.launcher, "-RotateStates", "--rotate-states", ",".join(rotation_states))
            if arguments.get("rotation_interval_ms") is not None:
                add_launch_arg(
                    command,
                    self.launcher,
                    "-RotationIntervalMs",
                    "--rotation-interval-ms",
                    int(arguments["rotation_interval_ms"]),
                )
            if arguments.get("frame_interval_ms") is not None:
                add_launch_arg(
                    command,
                    self.launcher,
                    "-FrameIntervalMs",
                    "--frame-interval-ms",
                    int(arguments["frame_interval_ms"]),
                )
            if arguments.get("rotate") is True:
                add_launch_arg(command, self.launcher, "-Rotate", "--rotate")

            popen_kwargs: dict[str, Any] = {"cwd": str(PROJECT_ROOT)}
            if os.name == "nt":
                popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
            subprocess.Popen(command, **popen_kwargs)
            return text_result("RubyOverlay launched.")

        if name == "ruby_overlay_create_shortcut":
            state = arguments.get("state") or "party"
            if state not in available_states:
                raise ValueError(f"Unknown RubyOverlay state '{state}'.")
            shortcut_path = create_desktop_shortcut(
                PROJECT_ROOT,
                self.launcher,
                str(arguments.get("name") or "Ruby Overlay"),
                str(state),
                int(arguments.get("height") or 800),
                bool(arguments.get("rotate", True)),
            )
            return text_result(f"RubyOverlay desktop shortcut created: {shortcut_path}")

        raise ValueError(f"Unknown tool: {name}")


def handle_message(server: RubyOverlayServer, message: dict[str, Any]) -> None:
    message_id = message.get("id")
    method = message.get("method")

    if method == "initialize":
        params = message.get("params") or {}
        requested_version = params.get("protocolVersion") or "2024-11-05"
        write_response(
            message_id,
            {
                "protocolVersion": requested_version,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "ruby-overlay", "version": read_current_version()},
            },
        )
        return

    if method == "notifications/initialized":
        return

    if method == "tools/list":
        write_response(message_id, {"tools": tool_schemas()})
        return

    if method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, dict):
            raise ValueError("Tool arguments must be an object.")
        write_response(message_id, server.call_tool(str(name), arguments))
        return

    if method in {"resources/list", "prompts/list"}:
        key = "resources" if method == "resources/list" else "prompts"
        write_response(message_id, {key: []})
        return

    raise ValueError(f"Unsupported method: {method}")


def main() -> int:
    parser = argparse.ArgumentParser(description="RubyOverlay MCP stdio server")
    parser.add_argument("--control", type=Path, default=DEFAULT_CONTROL_PATH)
    parser.add_argument("--rotation-config", type=Path, default=DEFAULT_ROTATION_CONFIG_PATH)
    parser.add_argument("--frames", type=Path, default=DEFAULT_FRAME_ROOT)
    parser.add_argument("--launcher", type=Path, default=DEFAULT_LAUNCHER)
    args = parser.parse_args()

    server = RubyOverlayServer(
        args.control.resolve(),
        args.rotation_config.resolve(),
        args.frames.resolve(),
        args.launcher.resolve(),
    )

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError("MCP message must be a JSON object.")
            handle_message(server, message)
        except Exception as exc:
            message_id = None
            if "message" in locals() and isinstance(message, dict):
                message_id = message.get("id")
            write_error(message_id, -32000, str(exc))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
