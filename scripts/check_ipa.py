#!/usr/bin/env python3
"""Check the production IPA and derive update metadata from the app being shipped."""
import argparse
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import zipfile


def check_ipa(path):
    with zipfile.ZipFile(path) as ipa:
        names = ipa.namelist()
        infos = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(infos) != 1:
            raise ValueError("IPA must contain exactly one app")
        app = infos[0].removesuffix("Info.plist")
        info = plistlib.loads(ipa.read(infos[0]))
        if info.get("CFBundleIdentifier") != "com.simpilot.efb":
            raise ValueError("IPA must use the production bundle identifier")
        if info.get("DTPlatformName") != "iphoneos":
            raise ValueError("IPA must contain an iOS device build")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or app + executable not in names:
            raise ValueError("App executable is missing")
        forbidden = {"TestCharts", ".git", ".env", "Local.xcconfig", "Signing.xcconfig", "CLAUDE.md", "AGENTS.md"}
        for name in names:
            parts = PurePosixPath(name).parts
            if forbidden.intersection(parts) or any(part.endswith(".xctest") for part in parts):
                raise ValueError(f"Development-only file in IPA: {name}")
        version = info.get("CFBundleShortVersionString", "")
        build = info.get("CFBundleVersion", "")
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
            raise ValueError("App version must contain numeric components")
        if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
            raise ValueError("App build must be a positive integer")
        return {"version": version, "build": int(build)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    try:
        metadata = check_ipa(args.ipa)
        args.manifest.write_text(json.dumps(metadata) + "\n")
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f"IPA validation failed: {error}\n")
    print(f"Verified production IPA: {metadata['version']} ({metadata['build']})")
