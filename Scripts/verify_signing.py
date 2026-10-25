#!/usr/bin/env python3
"""Verify the built App and Packet Tunnel against their embedded development profiles."""
from pathlib import Path
import argparse
import datetime
import json
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", nargs="?", type=Path, default=ROOT / ".build/ReleaseDevice/Build/Products/Release-iphoneos/DashInto.app")
parser.add_argument("--report", type=Path)
args = parser.parse_args()
app = args.app.resolve()
def run(*command):
    return subprocess.run(command, check=True, capture_output=True).stdout
def plist(path):
    return plistlib.loads(path.read_bytes())
def entitlements(path):
    return plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(path)))
run("codesign", "--verify", "--deep", "--strict", str(app))
records = []
for bundle in [app, app / "PlugIns/ClashDashTunnel.appex"]:
    info = plist(bundle / "Info.plist")
    signed = entitlements(bundle)
    profile = plistlib.loads(run("security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")))
    allowed = profile["Entitlements"]
    identity = info["CFBundleIdentifier"]
    group = info["DashAppGroup"]
    team = signed["com.apple.developer.team-identifier"]
    assert profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), "Expired profile"
    assert signed["application-identifier"] == f"{team}.{identity}", "Bundle identity mismatch"
    assert allowed["application-identifier"] == signed["application-identifier"], "Profile identity mismatch"
    assert "packet-tunnel-provider" in signed["com.apple.developer.networking.networkextension"], "Missing Packet Tunnel entitlement"
    assert "packet-tunnel-provider" in allowed["com.apple.developer.networking.networkextension"], "Profile does not permit Packet Tunnel"
    assert group in signed["com.apple.security.application-groups"] and group in allowed["com.apple.security.application-groups"], "App Group mismatch"
    keychain = info["DashKeychainGroup"]
    assert keychain in signed["keychain-access-groups"], "Shared Keychain mismatch"
    assert any(keychain == value or (value.endswith("*") and keychain.startswith(value[:-1])) for value in allowed["keychain-access-groups"]), "Profile does not permit Keychain group"
    records.append({"bundleID": identity, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "team": team,
                    "appGroup": group, "keychainGroup": keychain, "profileExpires": profile["ExpirationDate"].isoformat(), "passed": True})
assert records[0]["team"] == records[1]["team"]
assert records[0]["appGroup"] == records[1]["appGroup"]
assert records[0]["keychainGroup"] == records[1]["keychainGroup"]
report = json.dumps({"signatureVerified": True, "bundles": records}, ensure_ascii=False, indent=2)
if args.report:
    args.report.write_text(report + "\n")
print(report)
