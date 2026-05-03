import importlib.util
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

    def test_shipped_assets_include_samba_state(self):
        module = load_module()

        states = module.list_states(MODULE_PATH.parents[1] / "assets" / "frames")

        self.assertIn("samba", states)


if __name__ == "__main__":
    unittest.main()
