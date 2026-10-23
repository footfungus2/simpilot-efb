import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile

from check_ipa import check_ipa


class CheckIPATests(unittest.TestCase):
    def check(self, overrides=None, extra=()):
        info = {
            "CFBundleIdentifier": "com.simpilot.efb",
            "DTPlatformName": "iphoneos",
            "CFBundleExecutable": "SimPilotEFB",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "42",
        }
        info.update(overrides or {})
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "app.ipa"
            with zipfile.ZipFile(path, "w") as ipa:
                ipa.writestr("Payload/SimPilotEFB.app/Info.plist", plistlib.dumps(info))
                ipa.writestr("Payload/SimPilotEFB.app/SimPilotEFB", b"binary")
                for name in extra:
                    ipa.writestr(name, b"")
            return check_ipa(path)

    def test_manifest_matches_packaged_version_and_build(self):
        self.assertEqual(self.check(), {"version": "0.1.0", "build": 42})

    def test_rejects_development_bundle_and_simulator(self):
        for override in ({"CFBundleIdentifier": "com.simpilot.efb.dev"}, {"DTPlatformName": "iphonesimulator"}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                self.check(override)

    def test_rejects_invalid_update_metadata(self):
        for override in ({"CFBundleShortVersionString": "0.1-beta"}, {"CFBundleVersion": "0"}, {"CFBundleVersion": "1.2"}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                self.check(override)

    def test_rejects_development_files_and_personal_chart_pdfs(self):
        for item in ("TestCharts/chart.pdf", "TestCharts/manifest.json", ".env", "Local.xcconfig", "PlugIns/Tests.xctest/Tests"):
            with self.subTest(item=item), self.assertRaises(ValueError):
                self.check(extra=(f"Payload/SimPilotEFB.app/{item}",))

    def test_rejects_missing_executable_and_multiple_apps(self):
        with self.assertRaises(ValueError):
            self.check({"CFBundleExecutable": "Missing"})
        with self.assertRaises(ValueError):
            self.check(extra=("Payload/Other.app/Info.plist",))


if __name__ == "__main__":
    unittest.main()
