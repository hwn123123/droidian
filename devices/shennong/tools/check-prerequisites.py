#!/usr/bin/env python3
"""Check captured Android properties and a kernel config without device writes."""
import argparse
import gzip
import json
import re
from pathlib import Path

DEVICE = Path(__file__).resolve().parents[1]


def read_config(path):
    data = path.read_bytes()
    if data.startswith(b"\x1f\x8b"):
        data = gzip.decompress(data)
    config = {}
    for line in data.decode().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            config[key] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            config[line.split()[1]] = "n"
    if not config:
        raise ValueError("No kernel configuration was found")
    return config


def read_properties(path):
    result = {}
    for line in path.read_text().splitlines():
        bracketed = re.fullmatch(r"\[([^]]+)\]: \[([^]]*)\]", line)
        if bracketed:
            result[bracketed[1]] = bracketed[2]
        elif "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--properties", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--profile", choices=("display", "halium"), default="display")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    profile = json.loads((DEVICE / "profile.json").read_text())
    properties = read_properties(args.properties)
    config = read_config(args.config)
    required = read_config(DEVICE / f"kernel/{args.profile}.config")
    expected = {
        "ro.product.device": profile["device"],
        "ro.vendor.build.version.sdk": str(profile["vendor_api"]),
        "ro.vndk.version": profile["vendor_vndk"],
    }
    mismatches = {
        key: {"expected": value, "actual": properties.get(key)}
        for key, value in expected.items() if properties.get(key) != value
    }
    missing = {
        key: {"expected": value, "actual": config.get(key, "n")}
        for key, value in required.items() if config.get(key, "n") != value
    }
    result = {
        "device": profile["device"], "vendor_api": profile["vendor_api"],
        "kernel_profile": args.profile,
        "vendor_matches": not mismatches, "kernel_ready": not missing,
        "property_mismatches": mismatches, "kernel_changes_required": missing,
    }
    output = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(output)
    print(output, end="")
    return 0 if not mismatches and not missing else 1


if __name__ == "__main__":
    raise SystemExit(main())
