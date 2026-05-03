import http.server
import json
import os
import shutil
import subprocess
import threading
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class GitHubStub(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/repos/owner/repo/releases/latest":
            self.send_response(404)
            self.end_headers()
            return
        if self.path == "/repos/owner/repo/tags?per_page=1":
            payload = json.dumps([{"name": "v9.9.9"}]).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        return


@unittest.skipUnless(os.name == "nt" and shutil.which("powershell.exe"), "Windows WPF startup test")
class WindowsStartupUpdateTests(unittest.TestCase):
    def test_macos_source_exposes_dance_mode_controls(self):
        source = (REPO_ROOT / "macos" / "RubyOverlayMac.swift").read_text(encoding="utf-8")

        self.assertIn("var mode = \"assistant\"", source)
        self.assertIn("var danceState", source)
        self.assertIn("var danceFrameIntervalMs", source)
        self.assertIn("case \"--mode\"", source)
        self.assertIn("Dance mode", source)
        self.assertIn("Assistant mode", source)
        self.assertIn("nohup", source)

        installer = (REPO_ROOT / "macos" / "Install-RubyOverlayShortcut.command").read_text(encoding="utf-8")
        self.assertIn("nohup", installer)

    def test_widget_script_exposes_dance_mode_controls(self):
        script = (REPO_ROOT / "Start-RubyOverlay.ps1").read_text(encoding="utf-8")

        self.assertIn("[string]$Mode", script)
        self.assertIn("[string]$DanceState", script)
        self.assertIn("[int]$DanceFrameIntervalMs", script)
        self.assertIn("Dance mode", script)
        self.assertIn("Assistant mode", script)
        self.assertIn("ruby-icon.ico", script)
        self.assertIn("IconLocation", script)

        installer = (REPO_ROOT / "Install-RubyOverlayShortcut.ps1").read_text(encoding="utf-8")
        self.assertIn("ruby-icon.ico", installer)
        self.assertIn("IconLocation", installer)

    def test_widget_accepts_dance_mode_launch_arguments(self):
        temp_root = REPO_ROOT / ".test-tmp" / "dance-startup"
        if temp_root.exists():
            shutil.rmtree(temp_root)
        temp_root.mkdir(parents=True)
        try:
            source_frame = next((REPO_ROOT / "assets" / "frames" / "samba").glob("*.png"))
            frame_root = temp_root / "frames"
            dance_dir = frame_root / "dance-test"
            dance_dir.mkdir(parents=True)
            shutil.copy2(source_frame, dance_dir / "001.png")

            result = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-STA",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(REPO_ROOT / "Start-RubyOverlay.ps1"),
                    "-FrameRoot",
                    str(frame_root),
                    "-State",
                    "dance-test",
                    "-Mode",
                    "dance",
                    "-DanceState",
                    "dance-test",
                    "-DanceFrameIntervalMs",
                    "750",
                    "-Height",
                    "240",
                    "-CloseAfterMs",
                    "1000",
                    "-DisableUpdateCheck",
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                timeout=20,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            if temp_root.exists():
                shutil.rmtree(temp_root)

    def test_startup_update_check_writes_update_notice_control(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GitHubStub)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        temp_root = REPO_ROOT / ".test-tmp" / "startup-update"
        if temp_root.exists():
            shutil.rmtree(temp_root)
        temp_root.mkdir(parents=True)
        try:
            control_path = temp_root / "control.json"
            rotation_path = temp_root / "rotation.json"
            update_path = temp_root / "update.json"
            version_path = temp_root / "VERSION"
            rotation_path.write_text(
                json.dumps(
                    {
                        "enabled": True,
                        "intervalMs": 30000,
                        "frameIntervalMs": 9000,
                        "states": ["party", "samba"],
                    }
                ),
                encoding="utf-8",
            )
            update_path.write_text(
                json.dumps(
                    {
                        "repository": "owner/repo",
                        "updateState": "update",
                        "fallbackStates": ["deploy", "party"],
                    }
                ),
                encoding="utf-8",
            )
            version_path.write_text("0.0.0\n", encoding="utf-8")

            result = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-STA",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(REPO_ROOT / "Start-RubyOverlay.ps1"),
                    "-Height",
                    "240",
                    "-State",
                    "party",
                    "-CloseAfterMs",
                    "7000",
                    "-ControlPath",
                    str(control_path),
                    "-RotationConfigPath",
                    str(rotation_path),
                    "-UpdateConfigPath",
                    str(update_path),
                    "-VersionPath",
                    str(version_path),
                    "-UpdateApiBaseUrl",
                    f"http://127.0.0.1:{server.server_port}",
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                timeout=20,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            control = json.loads(control_path.read_text(encoding="utf-8-sig"))
            self.assertTrue(control["updateAvailable"])
            self.assertEqual(control["state"], "update")
            self.assertEqual(control["rotationStates"][:3], ["update", "party", "samba"])
            self.assertEqual(control["latestVersion"], "v9.9.9")

            update = json.loads(update_path.read_text(encoding="utf-8-sig"))
            self.assertEqual(update["lastCheck"]["versionSource"], "tag")
            self.assertEqual(update["lastCheck"]["latestVersion"], "v9.9.9")
        finally:
            server.shutdown()
            server.server_close()
            if temp_root.exists():
                shutil.rmtree(temp_root)


if __name__ == "__main__":
    unittest.main()
