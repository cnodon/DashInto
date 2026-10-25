#!/usr/bin/env python3
"""Compile the production importer against the pinned macOS SDK; synthetic fixtures plus an optional explicitly supplied private directory."""
from pathlib import Path
import json
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
lab = root / ".build/ImportLab"
sources = lab / "Sources/ImportProbe"
sources.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "ClashDashApp/NativeImport.swift", sources / "NativeImport.swift")
shutil.copy2(root / "ClashDashApp/NativeResourcePreparer.swift", sources / "NativeResourcePreparer.swift")
shutil.copy2(root / "Scripts/ImportProbe.swift", sources / "main.swift")
kit = str(root / "Packages/ClashDashKit")
sdk = str(root / "Vendor/Clash.xcframework/macos-arm64_x86_64")
quote = lambda value: json.dumps(value)
(lab / "Package.swift").write_text(f'''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ImportProbe", platforms: [.macOS(.v14)],
 dependencies: [.package(path: {quote(kit)})],
 targets: [.executableTarget(name: "ImportProbe", dependencies: [.product(name: "ClashDashKit", package: "ClashDashKit")],
 swiftSettings: [.unsafeFlags(["-F", {quote(sdk)}])],
 linkerSettings: [.unsafeFlags(["-F", {quote(sdk)}, "-framework", "Clash", "-lresolv"])])])
''')
subprocess.run(["swift", "run", "--package-path", str(lab), "ImportProbe", str(root)] + sys.argv[1:], check=True)
