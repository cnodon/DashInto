#!/usr/bin/env python3
"""Build, verify, install and launch on an explicitly selected paired iPhone. Does not start VPN."""
from pathlib import Path
import argparse
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True, help="CoreDevice identifier from: xcrun devicectl list devices")
args = parser.parse_args()
def run(command):
    subprocess.run(command, cwd=ROOT, check=True)
run([sys.executable, "Scripts/generate_project.py"])
log = ROOT / ".build/device-release-final.log"
log.parent.mkdir(exist_ok=True)
print("构建 Release；详细输出：", log, flush=True)
with log.open("w") as output:
    subprocess.run(["xcodebuild", "-project", "ClashDash.xcodeproj", "-scheme", "ClashDash", "-configuration", "Release", "-destination", "generic/platform=iOS", "-derivedDataPath", ".build/ReleaseDevice", "build"], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
app = ROOT / ".build/ReleaseDevice/Build/Products/Release-iphoneos/DashInto.app"
run([sys.executable, "Scripts/verify_signing.py", str(app), "--report", str(ROOT / ".build/release-signing-verification.json")])
run(["xcrun", "devicectl", "device", "install", "app", "--device", args.device, str(app)])
bundle = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
run(["xcrun", "devicectl", "device", "process", "launch", "--device", args.device, bundle])
print("已启动。请在手机导入订阅并允许 iOS 添加 VPN 配置。")
