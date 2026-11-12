#!/usr/bin/env python3
"""Capture mounted stock HAL images over authorized root ADB; read-only on device."""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
from pathlib import Path

PARTITIONS = ("vendor", "odm", "vendor_dlkm", "system_dlkm")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    adb = ["adb", "-s", args.serial]

    def shell(command, root=False):
        if root:
            command = "su -c " + shlex.quote(command)
        return subprocess.check_output(adb + ["shell", command], text=True).strip()

    if shell("getprop ro.product.device") != "shennong":
        raise SystemExit("The attached device is not shennong")
    if shell("getprop ro.vndk.version") != "34":
        raise SystemExit("This capture requires the stock VNDK 34 vendor")
    if "uid=0(" not in shell("id", root=True):
        raise SystemExit("Authorized root ADB is required")
    mounts = [line.split() for line in shell("cat /proc/mounts", root=True).splitlines()]
    manifest = {
        "device": "shennong", "vendor_vndk": "34",
        "vendor_fingerprint": shell("getprop ro.vendor.build.fingerprint"),
        "kernel_release": shell("uname -r"), "images": {},
    }
    args.output.mkdir(parents=True, exist_ok=True)
    for name in PARTITIONS:
        matching = [m for m in mounts if m[1] == "/" + name]
        if len(matching) != 1:
            raise SystemExit(f"No unambiguous mounted /{name} image")
        node, _, filesystem, options = matching[0][:4]
        if not re.fullmatch(r"/dev/(?:block/)?(?:dm-[0-9]+|mapper/[A-Za-z0-9_-]+)", node):
            raise SystemExit(f"Unexpected block device: {node}")
        if filesystem not in ("erofs", "ext4") or "ro" not in options.split(","):
            raise SystemExit(f"/{name} is not a supported read-only stock mount")
        size = int(shell("blockdev --getsize64 " + shlex.quote(node), root=True))
        if not 0 < size <= 8 * 1024 ** 3:
            raise SystemExit(f"Unexpected image size for {name}: {size}")
        image = args.output / f"{name}.img"
        partial = image.with_suffix(".img.partial")
        command = "su -c " + shlex.quote("cat " + shlex.quote(node))
        with partial.open("wb") as output:
            subprocess.run(adb + ["exec-out", command], stdout=output, check=True)
        if partial.stat().st_size != size:
            raise SystemExit(f"Incomplete capture: {name}")
        sha = hashlib.sha256()
        with partial.open("rb") as stream:
            for chunk in iter(lambda: stream.read(4 * 1024 ** 2), b""):
                sha.update(chunk)
        image_hash = sha.hexdigest()
        remote_hash = shell("sha256sum " + shlex.quote(node), root=True).split()[0]
        if image_hash != remote_hash:
            raise SystemExit(f"Device/readback hash mismatch: {name}")
        partial.replace(image)
        manifest["images"][name] = {
            "filename": image.name, "size": size, "sha256": image_hash,
            "filesystem": filesystem,
        }
        print(f"Captured and verified {name}: {size} bytes", flush=True)
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
