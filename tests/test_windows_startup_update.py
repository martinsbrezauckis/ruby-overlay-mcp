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
