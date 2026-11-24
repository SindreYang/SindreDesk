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

    def test_ui_single_declaration(self):
        text = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertEqual(text.count("class SindreHome extends"), 1)
        self.assertEqual(text.count("bool validServer("), 1)

    def test_workflow_release_only(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            text = path.read_text()
            self.assertIn("on:\n  release:\n    types: [published]", text)

if __name__ == "__main__":
    unittest.main()
