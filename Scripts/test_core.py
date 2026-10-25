#!/usr/bin/env python3
"""Exercise the pinned kernel against a separate loopback Shadowsocks reference server."""
from pathlib import Path
import http.server
import json
import os
import socket
import struct
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / ".build/CoreLab"
LAB.mkdir(parents=True, exist_ok=True)
reference = os.environ.get("CLASHDASH_REFERENCE_CORE", "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo")
if not Path(reference).is_file():
    raise SystemExit("Set CLASHDASH_REFERENCE_CORE to a mihomo executable. The test uses a separate config and loopback ports.")
counts = {"http": 0, "dns": 0}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        counts["http"] += 1
        self.send_response(204)
        self.end_headers()
    def do_HEAD(self): self.do_GET()
    def log_message(self, *args): pass
http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=http.serve_forever, daemon=True).start()
dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
dns.bind(("127.0.0.1", 0))
def answer_dns():
    while True:
        try: data, peer = dns.recvfrom(4096)
        except OSError: return
        counts["dns"] += 1
        cursor = 12
        while cursor < len(data) and data[cursor]: cursor += data[cursor] + 1
        question = data[12:cursor + 5]
        answer = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\xcb\x00\x71\x07"
        dns.sendto(data[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + question + answer, peer)
threading.Thread(target=answer_dns, daemon=True).start()
reserve = socket.socket(); reserve.bind(("127.0.0.1", 0)); port = reserve.getsockname()[1]; reserve.close()
password = "clashdash-local-integration-only"
(LAB / "server.yaml").write_text(f"""mode: direct
log-level: warning
listeners:
  - name: lab-shadowsocks
    type: shadowsocks
    listen: 127.0.0.1
    port: {port}
    cipher: aes-128-gcm
    password: {password}
    udp: true
dns:
  enable: false
""")
(LAB / "client.yaml").write_text(f"""mode: rule
log-level: silent
proxies:
  - name: LoopbackSS
    type: ss
    server: 127.0.0.1
    port: {port}
    cipher: aes-128-gcm
    password: {password}
    udp: true
proxy-groups:
  - name: Select
    type: select
    proxies: [LoopbackSS, DIRECT]
rules: ["MATCH,Select"]
tun:
  enable: false
dns:
  enable: true
  enhanced-mode: redir-host
  nameserver: ["udp://127.0.0.1:{dns.getsockname()[1]}#Select"]
  default-nameserver: [1.1.1.1]
""")
# Match the app's immutable provider snapshot design using a local file provider.
(LAB / "providers").mkdir(exist_ok=True)
(LAB / "providers/lab.yaml").write_text(f"""proxies:
  - name: LoopbackSS
    type: ss
    server: 127.0.0.1
    port: {port}
    cipher: aes-128-gcm
    password: {password}
    udp: true
""")
client = (LAB / "client.yaml").read_text()
provider = client[:client.index("proxies:\n")] + """proxy-providers:
  lab:
    type: file
    path: providers/lab.yaml
proxy-groups:
  - name: Select
    type: select
    proxies: [DIRECT]
    use: [lab]
""" + client[client.index("rules: "):]
(LAB / "provider-client.yaml").write_text(provider)
subprocess.run(["swiftc", str(ROOT / "Scripts/CoreProbe.swift"), "-F", str(ROOT / "Vendor/Clash.xcframework/macos-arm64_x86_64"), "-framework", "Clash", "-lresolv", "-o", str(LAB / "probe")], check=True)
with (LAB / "reference.log").open("w") as log:
    server = subprocess.Popen([reference, "-d", str(LAB / "server"), "-f", str(LAB / "server.yaml")], stdout=log, stderr=log)
    try:
        for _ in range(50):
            if server.poll() is not None: raise RuntimeError("Reference server failed; inspect .build/CoreLab/reference.log")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1): break
            except OSError: time.sleep(.1)
        outputs = []
        for config in ["client.yaml", "provider-client.yaml"]:
            result = subprocess.run([str(LAB / "probe"), str(LAB), f"http://127.0.0.1:{http.server_port}/generate_204", config], capture_output=True, text=True, timeout=45)
            print(config, result.stdout)
            if result.returncode: print(result.stderr[-4000:]); raise RuntimeError("Kernel integration probe failed")
            outputs += [config] + result.stdout.splitlines()
        assert counts["http"] > 0 and counts["dns"] > 0, counts
        report = {"passed": True, "platform": "macOS userland, not iOS Packet Tunnel", "fileProviderSnapshotPassed": True, "tcpShadowsocksHTTPRequests": counts["http"], "udpShadowsocksDNSRequests": counts["dns"], "coreOutput": outputs}
        (LAB / "result.json").write_text(json.dumps(report, indent=2))
        print(json.dumps({k:v for k,v in report.items() if k != "coreOutput"}, ensure_ascii=False))
    finally:
        server.terminate()
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.kill()
        http.shutdown(); dns.close()
