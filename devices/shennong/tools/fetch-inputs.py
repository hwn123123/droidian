#!/usr/bin/env python3
"""Verify the Droidian archive signature and pin the display bring-up inputs."""
import argparse
import concurrent.futures
import gzip
import hashlib
import json
import subprocess
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath

DEVICE = Path(__file__).resolve().parents[1]
REPO = DEVICE.parents[1]
MIRROR = "http://releases.droidian.org/snapshots"
KEYRING = REPO / "rootfs-templates/apt/etc/apt/trusted.gpg.d/droidian-bootstrap.gpg"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def download(url, path, expected=None, *, offline=False):
    if path.is_file() and expected and digest(path.read_bytes()) == expected:
        return path.read_bytes()
    if offline:
        if path.is_file() and expected is None:
            return path.read_bytes()
        raise ValueError(f"Missing or invalid cached input: {path}")
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read()
    if expected and digest(data) != expected:
        raise ValueError(f"SHA256 mismatch: {url}")
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_bytes(data)
    temporary.replace(path)
    return data


def fields(paragraph):
    result = {}
    for line in paragraph.splitlines():
        if line and not line[0].isspace() and ": " in line:
            key, value = line.split(": ", 1)
            result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--offline", action="store_true",
                        help="Verify and use signed cached inputs without network access")
    args = parser.parse_args()
    profile = json.loads((DEVICE / "profile.json").read_text())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    base = f"{MIRROR}/{profile['channel']}/"
    release = download(base + "dists/rolling/Release", output / "Release", offline=args.offline)
    download(base + "dists/rolling/Release.gpg", output / "Release.gpg", offline=args.offline)
    with tempfile.TemporaryDirectory(prefix="droidian-keyring-") as home:
        subprocess.run([
            "gpgv", "--homedir", home, "--keyring", str(KEYRING),
            str(output / "Release.gpg"), str(output / "Release"),
        ], check=True)
    hashes = {}
    in_sha256 = False
    for line in release.decode().splitlines():
        if not line.startswith(" "):
            in_sha256 = line == "SHA256:"
        elif in_sha256:
            sha, size, name = line.split()
            hashes[name] = (sha, int(size))
    packages = {}
    for arch in ("arm64", "all"):
        relative = f"main/binary-{arch}/Packages.gz"
        expected_sha, expected_size = hashes[relative]
        data = download(base + "dists/rolling/" + relative,
                        output / f"Packages-{arch}.gz", expected_sha, offline=args.offline)
        if len(data) != expected_size:
            raise ValueError(f"Index size mismatch: {relative}")
        for paragraph in gzip.decompress(data).decode().split("\n\n"):
            package = fields(paragraph)
            if package.get("Package") in profile["packages"]:
                name = package["Package"]
                if name in packages:
                    raise ValueError(f"Ambiguous archive entry: {name}")
                filename = PurePosixPath(package["Filename"])
                if filename.is_absolute() or ".." in filename.parts:
                    raise ValueError(f"Unsafe package filename: {filename}")
                packages[name] = {
                    "version": package["Version"], "architecture": package["Architecture"],
                    "filename": str(filename), "sha256": package["SHA256"],
                    "size": int(package["Size"]),
                    "url": base + urllib.parse.quote(str(filename), safe="/+"),
                }
    missing = sorted(set(profile["packages"]) - packages.keys())
    if missing:
        raise ValueError(f"Missing API {profile['vendor_api']} inputs: {missing}")
    lock = {
        "device": profile["device"], "channel": profile["channel"],
        "vendor_api": profile["vendor_api"], "release_sha256": digest(release),
        "packages": packages,
    }
    if args.download:
        package_dir = output / "packages"
        package_dir.mkdir(exist_ok=True)

        def fetch(item):
            name, package = item
            path = package_dir / PurePosixPath(package["filename"]).name
            data = download(package["url"], path, package["sha256"], offline=args.offline)
            if len(data) != package["size"]:
                raise ValueError(f"Package size mismatch: {name}")
            print(f"Verified {name} {package['version']}", flush=True)

        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            list(executor.map(fetch, packages.items()))
    (output / "inputs.lock.json").write_text(json.dumps(lock, indent=2) + "\n")
    print(f"Verified {len(packages)} inputs; lock: {output / 'inputs.lock.json'}")


if __name__ == "__main__":
    main()
