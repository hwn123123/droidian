#!/usr/bin/env python3
"""Transfer a locally verified image to authenticated REC and run its installer."""
import argparse
import hashlib
import shlex
import socket
import subprocess
import time
from pathlib import Path

STAGE = "/tmp/dri"
PORT = 49420


def sha256(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024**2), b""):
            result.update(block)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("payload", type=Path)
    parser.add_argument("--serial", required=True)
    args = parser.parse_args()
    payload = args.payload.resolve()
    adb = ["adb", "-s", args.serial]

    def shell(command):
        return subprocess.run(adb + ["shell", command], check=True,
                              text=True, capture_output=True).stdout.strip()

    def root(command):
        if len(command.encode()) > 80:
            raise ValueError("REC root bridge command exceeds 80 bytes")
        return shell("/nwrt/bin/nwrt-root " + shlex.quote(command))

    if subprocess.check_output(adb + ["get-state"], text=True).strip() != "recovery":
        raise RuntimeError("Enter the existing authenticated REC before installation")
    if shell("getprop ro.boot.slot_suffix") != "_a":
        raise RuntimeError("Use slot-A REC; this installer writes only Linux/B")
    checks = []
    for line in (payload / "PAYLOAD-SHA256SUMS").read_text().splitlines():
        digest, name = line.split()
        if Path(name).name != name or not name.replace("-", "").replace("_", "").replace(".", "").isalnum():
            raise ValueError("Unsafe payload filename")
        if sha256(payload / name) != digest:
            raise ValueError("Payload hash mismatch: " + name)
        checks.append(name)
    required = {"boot_b.img", "init_boot_b.img", "linux_root-droidian.simg",
                "PRESERVED-SHA256SUMS", "GPT-SHA256SUMS", "install.sh"}
    if not required.issubset(checks):
        raise ValueError("Incomplete installation manifest")
    total = sum((payload / name).stat().st_size for name in checks)
    available = int(shell("df -k /tmp | tail -n 1").split()[3]) * 1024
    if total + 512 * 1024**2 > available:
        raise RuntimeError("Not enough REC RAM for this payload")
    root("mkdir -p " + STAGE)
    subprocess.run(adb + ["forward", "tcp:" + str(PORT), "tcp:" + str(PORT)], check=True)

    def upload(path, name):
        # The existing REC policy permits an authenticated root receiver, but
        # forbids adbd creating files on tmpfs. Bind to loopback, use one
        # connection, and carry it only over this USB ADB forward.
        root(f"nc -ls127.0.0.1 -p{PORT} sh -c 'cat >{STAGE}/in' &")
        with socket.create_connection(("127.0.0.1", PORT), timeout=15) as connection:
            connection.settimeout(180)
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024**2), b""):
                    connection.sendall(block)
            connection.shutdown(socket.SHUT_WR)
            while connection.recv(1024):
                pass
        root(f"mv {STAGE}/in {STAGE}/{name}")
        print("Transferred " + name, flush=True)

    try:
        for name in checks + ["PAYLOAD-SHA256SUMS"]:
            upload(payload / name, name)
        runner = payload / "run-install.sh"
        runner.write_text(f"#!/system/bin/sh\nsh {STAGE}/install.sh {STAGE} >{STAGE}/install.log 2>&1\necho $? >{STAGE}/result\n")
        upload(runner, "run.sh")
        print("Installing Linux root and B boot images through REC", flush=True)
        root(f"rm -f {STAGE}/result; sh {STAGE}/run.sh &")
        for _ in range(180):
            time.sleep(5)
            result = root(f"cat {STAGE}/result 2>/dev/null || true")
            if result:
                print(root(f"tail -n 45 {STAGE}/install.log"), flush=True)
                if result != "0":
                    raise RuntimeError("REC installer failed with status " + result)
                print("Installation verified; device remains in REC", flush=True)
                return
        raise RuntimeError("Installer is still running; inspect its log before any reboot")
    finally:
        subprocess.run(adb + ["forward", "--remove", "tcp:" + str(PORT)], check=False)


if __name__ == "__main__":
    main()
