import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "mcp" / "ruby_overlay_mcp.py"


def load_module():
    spec = importlib.util.spec_from_file_location("ruby_overlay_mcp", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class RubyOverlayMcpTests(unittest.TestCase):
    def test_version_comparison_handles_v_prefix_and_numeric_segments(self):
        module = load_module()

        self.assertTrue(module.is_newer_version("v0.2.0", "0.1.9"))
        self.assertTrue(module.is_newer_version("1.0.1", "v1.0.0"))
        self.assertFalse(module.is_newer_version("v1.0.0", "1.0.0"))
        self.assertFalse(module.is_newer_version("v1.0.0", "1.0.1"))

    def test_check_update_uses_latest_release_metadata_without_network(self):
        module = load_module()

        result = module.check_for_update(
            repository="owner/repo",
            current_version="0.1.0",
            fetch_latest_release=lambda repository: {
                "tag_name": "v0.2.0",
                "html_url": "https://github.com/owner/repo/releases/tag/v0.2.0",
                "name": "Ruby Overlay 0.2.0",
            },
        )

        self.assertEqual(result["repository"], "owner/repo")
        self.assertEqual(result["currentVersion"], "0.1.0")
        self.assertEqual(result["latestVersion"], "v0.2.0")
        self.assertTrue(result["updateAvailable"])
        self.assertEqual(result["releaseUrl"], "https://github.com/owner/repo/releases/tag/v0.2.0")

    def test_check_update_falls_back_to_latest_tag_when_no_release_exists(self):
        module = load_module()

        class ReleaseNotFound(urllib.error.HTTPError):
            def __init__(self):
                Exception.__init__(self, "Not Found")
                self.code = 404

        def no_release(repository):
            raise ReleaseNotFound()

        result = module.check_for_update(
            repository="owner/repo",
            current_version="0.1.0",
            fetch_latest_release=no_release,
            fetch_latest_tag=lambda repository: {
                "name": "v0.1.0",
                "zipball_url": "https://api.github.com/repos/owner/repo/zipball/refs/tags/v0.1.0",
            },
        )

        self.assertEqual(result["latestVersion"], "v0.1.0")
        self.assertEqual(result["versionSource"], "tag")
        self.assertFalse(result["updateAvailable"])

    def test_update_notice_prefers_update_state_and_keeps_rotation_order(self):
        module = load_module()

        states = module.select_update_notice_states(
            available_states=["party", "deploy", "ruby-update", "review"],
            current_rotation_states=["party", "review"],
            update_state="ruby-update",
            fallback_states=["deploy"],
        )

        self.assertEqual(states, ["ruby-update", "party", "review"])

    def test_update_notice_falls_back_when_custom_update_state_missing(self):
        module = load_module()

        states = module.select_update_notice_states(
            available_states=["party", "deploy", "review"],
            current_rotation_states=["party", "review"],
            update_state="ruby-update",
            fallback_states=["deploy"],
        )

        self.assertEqual(states, ["deploy", "party", "review"])

    def test_update_notice_accepts_new_update_dataset_when_old_config_name_is_used(self):
        module = load_module()

        states = module.select_update_notice_states(
            available_states=["party", "update", "review"],
            current_rotation_states=["party", "review"],
            update_state="ruby-update",
            fallback_states=["deploy"],
        )

        self.assertEqual(states, ["update", "party", "review"])

    def test_update_notice_states_are_removed_when_installed_version_is_current(self):
        module = load_module()

        states = module.remove_update_notice_states(
            current_rotation_states=["update", "party", "ruby-update", "review"],
            update_state="update",
            fallback_states=["ruby-update", "deploy"],
        )

        self.assertEqual(states, ["party", "review"])

    def test_update_result_preserves_update_configuration(self):
        module = load_module()

        saved = module.updated_update_config(
            {
                "repository": "owner/repo",
                "updateState": "ruby-update",
                "fallbackStates": ["deploy"],
            },
            {
                "repository": "owner/repo",
                "currentVersion": "0.1.0",
                "latestVersion": "v0.2.0",
                "releaseUrl": "https://github.com/owner/repo/releases/tag/v0.2.0",
                "updateAvailable": True,
            },
        )

        self.assertEqual(saved["repository"], "owner/repo")
        self.assertEqual(saved["updateState"], "ruby-update")
        self.assertEqual(saved["fallbackStates"], ["deploy"])
        self.assertTrue(saved["lastCheck"]["updateAvailable"])

    def test_tool_list_exposes_ruby_command_and_update_check(self):
        module = load_module()

        tool_names = {schema["name"] for schema in module.tool_schemas()}

        self.assertIn("ruby", tool_names)
        self.assertIn("ruby_overlay_check_update", tool_names)
        self.assertIn("ruby_overlay_create_shortcut", tool_names)
        self.assertIn("ruby_overlay_set_mode", tool_names)

    @unittest.skipUnless(os.name == "nt", "Windows shortcut behavior is covered on Windows")
    def test_mcp_windows_shortcut_uses_detached_hidden_powershell(self):
        module = load_module()

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            launcher = root / "Run-RubyOverlay.cmd"
            launcher.write_text("@echo off\r\n", encoding="utf-8")
            icon_dir = root / "assets"
            icon_dir.mkdir()
            shutil.copy2(MODULE_PATH.parents[1] / "assets" / "ruby-icon.ico", icon_dir / "ruby-icon.ico")
            for path in [Path.home() / "Desktop" / "Ruby Test.cmd", Path.home() / "Desktop" / "Ruby Test.lnk"]:
                if path.exists():
                    path.unlink()

            previous_os_name = module.os.name
            try:
                module.os.name = "nt"
                shortcut = module.create_desktop_shortcut(root, launcher, "Ruby Test", "samba", 640, True)
            finally:
                module.os.name = previous_os_name

            if os.name == "nt" and shutil.which("powershell.exe") and shortcut.suffix.lower() == ".lnk":
                result = subprocess.run(
                    [
                        "powershell.exe",
                        "-NoProfile",
                        "-ExecutionPolicy",
                        "Bypass",
                        "-Command",
                        (
                            "$shortcut=(New-Object -ComObject WScript.Shell)."
                            f"CreateShortcut('{shortcut}');"
                            "Write-Output $shortcut.TargetPath;"
                            "Write-Output $shortcut.Arguments;"
                            "Write-Output $shortcut.IconLocation"
                        ),
                    ],
                    text=True,
                    capture_output=True,
                    timeout=20,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("powershell.exe", result.stdout)
                self.assertIn("-WindowStyle Hidden", result.stdout)
                self.assertIn("Start-RubyOverlay.ps1", result.stdout)
                self.assertIn('-State "samba"', result.stdout)
                self.assertIn("-Height 640", result.stdout)
                self.assertIn("-Rotate", result.stdout)
                self.assertIn("ruby-icon.ico", result.stdout)
            else:
                content = shortcut.read_text(encoding="utf-8")
                self.assertIn('start "" powershell.exe', content)
                self.assertIn("-WindowStyle Hidden", content)
                self.assertIn("Start-RubyOverlay.ps1", content)
                self.assertIn('-State "samba"', content)
                self.assertIn("-Height 640", content)
                self.assertIn("-Rotate", content)
            shortcut.unlink(missing_ok=True)

    def test_shipped_assets_include_samba_state(self):
        module = load_module()

        states = module.list_states(MODULE_PATH.parents[1] / "assets" / "frames")

        self.assertIn("samba", states)

    def test_set_mode_dance_writes_dance_control_fields(self):
        module = load_module()

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frame_root = root / "frames"
            dance_dir = frame_root / "dance-samba"
            dance_dir.mkdir(parents=True)
            (dance_dir / "001.png").write_bytes(b"placeholder")
            control_path = root / "control.json"
            rotation_path = root / "rotation.json"
            launcher = root / "Run-RubyOverlay.cmd"

            server = module.RubyOverlayServer(control_path, rotation_path, frame_root, launcher)
            server.call_tool(
                "ruby_overlay_set_mode",
                {
                    "mode": "dance",
                    "dance_state": "dance-samba",
                    "dance_frame_interval_ms": 750,
                },
            )

            control = json.loads(control_path.read_text(encoding="utf-8"))

            self.assertEqual(control["mode"], "dance")
            self.assertEqual(control["state"], "dance-samba")
            self.assertEqual(control["danceState"], "dance-samba")
            self.assertEqual(control["danceFrameIntervalMs"], 750)
            self.assertFalse(control["rotate"])

    def test_set_mode_assistant_writes_assistant_control_mode(self):
        module = load_module()

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frame_root = root / "frames"
            idle_dir = frame_root / "idle"
            idle_dir.mkdir(parents=True)
            (idle_dir / "001.png").write_bytes(b"placeholder")
            control_path = root / "control.json"
            rotation_path = root / "rotation.json"
            launcher = root / "Run-RubyOverlay.cmd"

            server = module.RubyOverlayServer(control_path, rotation_path, frame_root, launcher)
            server.call_tool("ruby_overlay_set_mode", {"mode": "assistant"})

            control = json.loads(control_path.read_text(encoding="utf-8"))

            self.assertEqual(control["mode"], "assistant")
            self.assertNotIn("danceState", control)
            self.assertNotIn("danceFrameIntervalMs", control)


if __name__ == "__main__":
    unittest.main()
