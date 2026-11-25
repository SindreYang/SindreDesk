"""源码变换的快速回归测试，不替代跨平台构建。"""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_client", ROOT / "scripts/prepare-client.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareClientTests(unittest.TestCase):
    def test_replace_once(self):
        self.assertEqual(module.replace_once("a b", "a", "c"), "c b")
        for source in ("b", "a a"):
            with self.assertRaises(RuntimeError):
                module.replace_once(source, "a", "c")

    def test_regex_literal(self):
        self.assertEqual(module.replace_regex("a", "^a$", r"$&\\1"), r"$&\\1")

    def test_android_roles(self):
        for role in ("host", "client"):
            text = module.patch_gradle('applicationId "com.carriez.flutter_hbb"', role)
            self.assertIn(f'com.sindre.desk.{role}', text)
            self.assertIn('abiFilters "arm64-v8a"', text)

    def test_native_guard(self):
        source = ('pub fn main_start_service() {\n}\n'
                  '        log::debug!("startService from jvm");\n')
        result = module.patch_android_native(source)
        self.assertEqual(result.count("if config::is_outgoing_only()"), 2)
        self.assertNotIn(r"\n", result)
        self.assertIn("main_start_service() {\n    if", result)

    def test_ui_single_declaration(self):
        text = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertEqual(text.count("class SindreHome extends"), 1)
        self.assertEqual(text.count("bool validServer("), 1)

    def test_signing_properties_escape(self):
        signing_spec = importlib.util.spec_from_file_location(
            "write_android_signing", ROOT / "scripts/write-android-signing.py")
        signing = importlib.util.module_from_spec(signing_spec)
        signing_spec.loader.exec_module(signing)
        self.assertEqual(signing.escape("a b:c=d#e!"), r"a\ b\:c\=d\#e\!")
        self.assertEqual(signing.escape("a\\b"), r"a\\b")
        self.assertEqual(signing.escape("中"), r"\u4e2d")
        self.assertEqual(signing.escape("😀"), r"\ud83d\ude00")

    def test_legacy_host_config_patch(self):
        source = "        Config::with_extension(Self::path(name))"
        result = module.patch_legacy_host_config(source)
        self.assertIn('ProjectDirs::from("", "", "SindreDesk Host")', result)
        self.assertIn("create_new(true)", result)
        self.assertIn("std::fs::hard_link(&tmp, &path)", result)
        self.assertIn("return legacy;", result)
        with self.assertRaises(RuntimeError):
            module.patch_legacy_host_config("")

    def test_desktop_service_scope(self):
        source = (ROOT / "client/flutter/desktop_autostart.dart").read_text()
        self.assertIn("--install-service", source)
        self.assertIn("--uninstall-service", source)
        self.assertNotIn("Startup", source)
        self.assertNotIn("autostart/", source)
        ui = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertIn("Random.secure()", ui)
        self.assertIn("List.generate(6,", ui)
        self.assertIn("mainSetPermanentPasswordWithResult", ui)
        self.assertIn("DesktopAutostart.supported ? kUsePermanentPassword : kUseTemporaryPassword", ui)
        unit = (ROOT / "deploy/sindredesk-host.service").read_text()
        self.assertIn("ExecStart=/usr/lib/sindredesk-host/sindredesk-host --service", unit)

    def test_workflow_release_only(self):
        paths = sorted((ROOT / ".github/workflows").glob("*.yml"))
        self.assertEqual([p.name for p in paths], ["client-build-verify.yml", "server.yml"])
        for path in paths:
            text = path.read_text()
            self.assertIn("on:\n  release:\n    types: [published]", text)

if __name__ == "__main__":
    unittest.main()
