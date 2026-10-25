#!/usr/bin/env python3
"""TCP/UDP interoperability with a separate mihomo server; loopback and synthetic credentials only."""
from pathlib import Path
import base64
import hashlib
import http.server
import json
import os
import re
import socket
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / ".build/ProtocolLab"
LAB.mkdir(parents=True, exist_ok=True)
REFERENCE = os.environ.get("CLASHDASH_REFERENCE_CORE", "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo")
if not Path(REFERENCE).is_file():
    raise SystemExit("Set CLASHDASH_REFERENCE_CORE to an independent mihomo executable")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self): self.send_response(204); self.end_headers()
    def do_GET(self): self.do_HEAD()
    def log_message(self, *args): pass
http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=http.serve_forever, daemon=True).start()
dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); dns.bind(("127.0.0.1", 0))
def serve_dns():
    while True:
        try: data, peer = dns.recvfrom(4096)
        except OSError: return
        cursor = 12
        while cursor < len(data) and data[cursor]: cursor += data[cursor] + 1
        question = data[12:cursor + 5]
        answer = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\xcb\x00\x71\x07"
        dns.sendto(data[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + question + answer, peer)
threading.Thread(target=serve_dns, daemon=True).start()

subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout", str(LAB / "key.pem"), "-out", str(LAB / "cert.pem")], check=True, capture_output=True)
der = subprocess.run(["openssl", "x509", "-in", str(LAB / "cert.pem"), "-outform", "DER"], check=True, capture_output=True).stdout
fingerprint = hashlib.sha256(der).hexdigest()
probe = LAB / "probe"
subprocess.run(["swiftc", str(ROOT / "Scripts/CoreProbe.swift"), "-F", str(ROOT / "Vendor/Clash.xcframework/macos-arm64_x86_64"), "-framework", "Clash", "-lresolv", "-o", str(probe)], check=True)
PASSWORD = "clashdash-synthetic-local-only"
UUID = "b831381d-6324-4d53-ad4f-8cda48b30811"
tls_server = {"certificate": (LAB / "cert.pem").read_text(), "private-key": (LAB / "key.pem").read_text()}
tls_client = {"sni": "localhost", "fingerprint": fingerprint, "skip-cert-verify": False}
cases = [
    ("Shadowsocks AEAD", {"type": "shadowsocks", "cipher": "aes-128-gcm", "password": PASSWORD, "udp": True}, {"type": "ss", "cipher": "aes-128-gcm", "password": PASSWORD}, True),
    ("Shadowsocks 2022", {"type": "shadowsocks", "cipher": "2022-blake3-aes-128-gcm", "password": base64.b64encode(b"0123456789abcdef").decode(), "udp": True}, {"type": "ss", "cipher": "2022-blake3-aes-128-gcm", "password": base64.b64encode(b"0123456789abcdef").decode()}, True),
    ("Trojan TLS", {"type": "trojan", "users": [{"username": "test", "password": PASSWORD}], **tls_server}, {"type": "trojan", "password": PASSWORD, **tls_client}, True),
    ("Trojan WebSocket TLS", {"type": "trojan", "users": [{"username": "test", "password": PASSWORD}], "ws-path": "/ws", **tls_server}, {"type": "trojan", "password": PASSWORD, "network": "ws", "ws-opts": {"path": "/ws"}, **tls_client}, True),
    ("VMess TCP", {"type": "vmess", "users": [{"username": "test", "uuid": UUID}]}, {"type": "vmess", "uuid": UUID, "alterId": 0, "cipher": "auto"}, True),
    ("VMess WebSocket TLS", {"type": "vmess", "users": [{"username": "test", "uuid": UUID}], "ws-path": "/ws", **tls_server}, {"type": "vmess", "uuid": UUID, "alterId": 0, "cipher": "auto", "network": "ws", "ws-opts": {"path": "/ws"}, "tls": True, "servername": "localhost", **tls_client}, True),
    ("VLESS TLS", {"type": "vless", "users": [{"username": "test", "uuid": UUID}], **tls_server}, {"type": "vless", "uuid": UUID, "tls": True, "servername": "localhost", **tls_client}, True),
    ("Hysteria2", {"type": "hysteria2", "users": {"test": PASSWORD}, **tls_server}, {"type": "hysteria2", "password": PASSWORD, **tls_client}, True),
    ("TUIC v5", {"type": "tuic", "users": {UUID: PASSWORD}, "alpn": ["h3"], **tls_server}, {"type": "tuic", "uuid": UUID, "password": PASSWORD, "alpn": ["h3"], "congestion-controller": "cubic", **tls_client}, True),
    ("AnyTLS", {"type": "anytls", "users": {"test": PASSWORD}, **tls_server}, {"type": "anytls", "password": PASSWORD, **tls_client}, True),
    ("SOCKS5", {"type": "socks", "udp": True}, {"type": "socks5"}, True),
    ("HTTP CONNECT", {"type": "http"}, {"type": "http"}, False),
]
reports = []
try:
    for index, (name, inbound, outbound, udp) in enumerate(cases):
        folder = LAB / str(index); folder.mkdir(exist_ok=True)
        reservation = socket.socket(); reservation.bind(("127.0.0.1", 0)); port = reservation.getsockname()[1]; reservation.close()
        inbound = {"name": "reference", "listen": "127.0.0.1", "port": port, **inbound}
        outbound = {"name": "LoopbackSS", "server": "127.0.0.1", "port": port, "udp": True, **outbound}
        (folder / "server.json").write_text(json.dumps({"mode": "direct", "log-level": "warning", "listeners": [inbound], "dns": {"enable": False}}))
        client = {"mode": "rule", "log-level": "silent", "proxies": [outbound], "proxy-groups": [{"name": "Select", "type": "select", "proxies": ["LoopbackSS"]}], "rules": ["MATCH,Select"], "tun": {"enable": False}, "dns": {"enable": True, "enhanced-mode": "redir-host", "nameserver": [f"udp://127.0.0.1:{dns.getsockname()[1]}#Select"], "default-nameserver": ["1.1.1.1"]}}
        (folder / "client.json").write_text(json.dumps(client))
        with (folder / "reference.log").open("w") as log:
            server = subprocess.Popen([REFERENCE, "-d", str(folder / "server"), "-f", str(folder / "server.json")], stdout=log, stderr=log)
            try:
                time.sleep(.5)
                if server.poll() is not None or "listen err" in (folder / "reference.log").read_text():
                    reports.append({"name": name, "passed": False, "referenceAvailable": False})
                    print(name, "reference failed to start", flush=True); continue
                command = [str(probe), str(folder), f"http://127.0.0.1:{http.server_port}/generate_204", "client.json"]
                if not udp: command.append("tcp-only")
                result = subprocess.run(command, capture_output=True, text=True, timeout=40)
                (folder / "probe.log").write_text(result.stdout + result.stderr)
                tcp = re.search(r"TCP_SS_DELAY_MS\s+(-?\d+)", result.stdout)
                passed = result.returncode == 0
                report = {"name": name, "passed": passed, "referenceAvailable": True, "tcpHTTP": bool(tcp and int(tcp[1]) >= 0), "udpDNS": "203.0.113.7" in result.stdout if udp else None}
                if name == "Trojan TLS" and passed:
                    client["proxies"][0]["fingerprint"] = "00" * 32
                    (folder / "wrong-pin.json").write_text(json.dumps(client))
                    rejection = subprocess.run([str(probe), str(folder), f"http://127.0.0.1:{http.server_port}/generate_204", "wrong-pin.json", "reject-tls"], capture_output=True, text=True, timeout=25)
                    report["wrongCertificatePinRejected"] = rejection.returncode == 0
                    report["passed"] = passed and report["wrongCertificatePinRejected"]
                reports.append(report); print(json.dumps(report), flush=True)
            finally:
                server.terminate()
                try: server.wait(timeout=3)
                except subprocess.TimeoutExpired: server.kill(); server.wait()
finally:
    http.shutdown(); dns.close()
summary = {"platform": "macOS userland, not iOS Packet Tunnel", "reference": "separate mihomo process", "results": reports, "passed": all(item["passed"] for item in reports)}
(LAB / "result.json").write_text(json.dumps(summary, indent=2))
if not summary["passed"]: raise SystemExit(1)
