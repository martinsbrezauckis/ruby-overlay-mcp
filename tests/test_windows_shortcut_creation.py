import os
import shutil
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "nt" and shutil.which("powershell.exe"), "Windows shortcut test")
class WindowsShortcutCreationTests(unittest.TestCase):
    def test_widget_can_create_shortcut_from_shared_command_path(self):
        temp_root = REPO_ROOT / ".test-tmp" / "shortcut"
        shortcut_path = temp_root / "Ruby Overlay Test.cmd"
        if temp_root.exists():
            shutil.rmtree(temp_root)
        temp_root.mkdir(parents=True)
        try:
            result = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-STA",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(REPO_ROOT / "Start-RubyOverlay.ps1"),
                    "-CreateShortcutAndExit",
                    "-ShortcutPath",
                    str(shortcut_path),
                    "-State",
                    "samba",
                    "-Height",
                    "640",
                    "-Rotate",
                    "-DisableUpdateCheck",
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                timeout=20,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(shortcut_path.exists())
            content = shortcut_path.read_text(encoding="utf-8")
            self.assertIn("Run-RubyOverlay.cmd", content)
            self.assertIn("-State \"samba\"", content)
            self.assertIn("-Height 640", content)
            self.assertIn("-Rotate", content)
        finally:
            if temp_root.exists():
                shutil.rmtree(temp_root)


if __name__ == "__main__":
    unittest.main()
