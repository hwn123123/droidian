#!/usr/bin/env python3
"""Stage saved stock tethering libraries as private, checksummed build inputs."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

LIBRARIES = (
    "libcom.android.tethering.connectivity_native.so",
    "libcom.android.tethering.dns_helper.so",
    "libc++.so",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-lib64", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name in LIBRARIES:
        source = args.source_lib64 / name
        data = source.read_bytes()
        if data[:5] != b"\x7fELF\x02" or data[18:20] != b"\xb7\x00":
            raise SystemExit(f"Not a stock arm64 ELF library: {source}")
        shutil.copyfile(source, args.output / name)
        manifest[name] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Staged {len(manifest)} private NICM dependencies in {args.output}")


if __name__ == "__main__":
    main()
