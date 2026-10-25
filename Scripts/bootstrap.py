#!/usr/bin/env python3
"""Fetch the pinned Apple core and adapter without executing upstream scripts."""
import hashlib
import json
from pathlib import Path
import shutil
import stat
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
lock = json.loads((ROOT / "Dependencies.lock.json").read_text())
cache = ROOT / ".build"
cache.mkdir(exist_ok=True)
archive = cache / "Clash.xcframework.zip"
core = lock["kernel"]
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != core["sha256"]:
    print("Downloading pinned Apple core…", flush=True)
    temporary = archive.with_suffix(".download")
    with urllib.request.urlopen(core["asset"], timeout=90) as source, temporary.open("wb") as output:
        shutil.copyfileobj(source, output)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != core["sha256"]:
        raise SystemExit("Kernel SHA-256 does not match Dependencies.lock.json")
    temporary.replace(archive)
vendor = ROOT / "Vendor"
vendor.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="clash-sdk-", dir=cache) as temporary:
    staged = Path(temporary)
    with zipfile.ZipFile(archive) as bundle:
        links = []
        # Extract to a fresh directory. Never follow symlinks from an earlier bootstrap.
        for item in bundle.infolist():
            destination = staged / item.filename
            if Path(item.filename).is_absolute() or not destination.resolve().is_relative_to(staged):
                raise SystemExit("Unsafe archive member")
            if stat.S_ISLNK(item.external_attr >> 16):
                links.append(item)
            elif item.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(item) as source, destination.open("wb") as output:
                    shutil.copyfileobj(source, output)
        for item in links:
            destination = staged / item.filename
            target = bundle.read(item).decode()
            if Path(target).is_absolute() or not (destination.parent / target).resolve().is_relative_to(staged):
                raise SystemExit("Unsafe framework symlink")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(target)
    for source in staged.iterdir():
        destination = vendor / source.name
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        else:
            destination.unlink(missing_ok=True)
        source.rename(destination)
adapter = lock["adapter"]
for path, expected in adapter["files"].items():
    output = vendor / "ClashAdapter" / Path(path).name
    output.parent.mkdir(exist_ok=True)
    if output.is_file() and hashlib.sha256(output.read_bytes()).hexdigest() == expected:
        continue
    url = f'{adapter["repository"].replace("github.com", "raw.githubusercontent.com")}/{adapter["revision"]}/{path}'
    data = urllib.request.urlopen(url, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit(f"Adapter SHA-256 does not match: {path}")
    output.write_bytes(data)
print("Dependencies verified. Run python3 Scripts/generate_project.py")
