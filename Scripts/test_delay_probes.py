#!/usr/bin/env python3
"""Real pinned SDK + production delay queue. Synthetic loopback SS, no system VPN or private subscriptions."""
from pathlib import Path
import http.server
import json
import os
import socket
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / ".build/DelayRepairLab"
LAB.mkdir(parents=True, exist_ok=True)
REFERENCE = os.environ.get("CLASHDASH_REFERENCE_CORE", "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo")
if not Path(REFERENCE).is_file():
    raise SystemExit("Set CLASHDASH_REFERENCE_CORE to an independent mihomo executable")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        if self.path == "/slow":
            time.sleep(6)
        try:
            self.send_response(204)
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_GET(self):
        self.do_HEAD()
    def log_message(self, *args):
        pass

http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=http.serve_forever, daemon=True).start()
reservation = socket.socket()
reservation.bind(("127.0.0.1", 0))
port = reservation.getsockname()[1]
reservation.close()
password = "synthetic-loopback-only"
server = {"mode": "direct", "log-level": "silent", "dns": {"enable": False},
          "listeners": [{"name": "local", "type": "shadowsocks", "listen": "127.0.0.1", "port": port,
                         "cipher": "aes-128-gcm", "password": password}]}
client = {"mode": "rule", "log-level": "silent", "dns": {"enable": False}, "tun": {"enable": False},
          "proxies": [{"name": f"Local{i}", "type": "ss", "server": "127.0.0.1", "port": port,
                       "cipher": "aes-128-gcm", "password": password} for i in range(12)],
          "rules": ["MATCH,DIRECT"]}
(LAB / "server.json").write_text(json.dumps(server))
(LAB / "client.json").write_text(json.dumps(client))
sources = LAB / "Sources/DelayProbe"
sources.mkdir(parents=True, exist_ok=True)
# Reuse the existing host platform, which refuses to open a system tunnel.
platform = (ROOT / "Scripts/CoreProbe.swift").read_text().split("\nlet root =", 1)[0]
(sources / "HostPlatform.swift").write_text(platform)
(sources / "Probe.swift").write_text((ROOT / "Scripts/DelayProbe.swift").read_text())
sdk = str(ROOT / "Vendor/Clash.xcframework/macos-arm64_x86_64")
(LAB / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DelayProbe", platforms: [.macOS(.v14)],
 dependencies: [.package(path: %s)],
 targets: [.executableTarget(name: "DelayProbe", dependencies: [.product(name: "ClashDashKit", package: "ClashDashKit")],
 swiftSettings: [.unsafeFlags(["-F", %s])],
 linkerSettings: [.unsafeFlags(["-F", %s, "-framework", "Clash", "-lresolv"])])])
''' % (json.dumps(str(ROOT / "Packages/ClashDashKit")), json.dumps(sdk), json.dumps(sdk)))
subprocess.run(["swift", "build", "-c", "release", "--package-path", str(LAB)], check=True)
with (LAB / "reference.log").open("w") as log:
    process = subprocess.Popen([REFERENCE, "-d", str(LAB / "reference"), "-f", str(LAB / "server.json")], stdout=log, stderr=log)
    try:
        time.sleep(.5)
        if process.poll() is not None:
            raise RuntimeError("Loopback reference failed to start")
        url = f"http://127.0.0.1:{http.server_port}"
        result = subprocess.run([str(LAB / ".build/release/DelayProbe"), str(LAB), url + "/fast", url + "/slow"],
                                capture_output=True, text=True, timeout=45)
        (LAB / "probe.log").write_text(result.stdout + result.stderr)
        print(result.stdout, end="", flush=True)
        if result.returncode:
            raise RuntimeError("Pinned core delay regression failed; see .build/DelayRepairLab/probe.log")
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        http.shutdown()
