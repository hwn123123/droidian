#!/usr/bin/env python3
"""Validate captured primary and backup GPT sectors without using recovery ioctls."""
import argparse
import hashlib
import json
import struct
import uuid
import zlib
from pathlib import Path

SECTOR = 4096
SECTORS = 128626688
ROOT_GUID = "c675f892-57a0-4776-a8fd-17c15f0ad78a"


def header(data, offset, current, backup):
    values = struct.unpack_from("<8sIIIIQQQQ16sQIII", data, offset)
    signature, revision, length, checksum, reserved = values[:5]
    if (signature, revision, length, reserved) != (b"EFI PART", 0x10000, 92, 0):
        raise ValueError("Unexpected GPT header format")
    if values[5:9] != (current, backup, 6, SECTORS - 6):
        raise ValueError("Unexpected GPT disk bounds")
    raw = bytearray(data[offset:offset + length])
    struct.pack_into("<I", raw, 16, 0)
    if zlib.crc32(raw) != checksum:
        raise ValueError("GPT header CRC mismatch")
    if values[11:13] != (64, 128):
        raise ValueError("Unexpected partition table dimensions")
    return values


def validate(primary, backup):
    if len(primary) != 6 * SECTOR or len(backup) != 6 * SECTOR:
        raise ValueError("Expected the first and last six 4096-byte sectors")
    main = header(primary, SECTOR, 1, SECTORS - 1)
    other = header(backup, 5 * SECTOR, SECTORS - 1, 1)
    if main[9] != other[9] or main[10] != 2 or other[10] != SECTORS - 5:
        raise ValueError("Primary/backup disk identity or table location mismatch")
    table = primary[2 * SECTOR:4 * SECTOR]
    if table != backup[SECTOR:3 * SECTOR]:
        raise ValueError("Primary/backup partition tables differ")
    if zlib.crc32(table) != main[13] or main[13] != other[13]:
        raise ValueError("Partition table CRC mismatch")
    partitions = {}
    for index in range(64):
        entry = table[index * 128:(index + 1) * 128]
        if entry[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", entry, 32)
        label = entry[56:128].decode("utf-16-le").rstrip("\0")
        if label in partitions or not 6 <= first <= last <= SECTORS - 6:
            raise ValueError("Invalid partition label or bounds")
        partitions[label] = (index + 1, first, last, str(uuid.UUID(bytes_le=entry[16:32])))
    ordered = sorted(partitions.values(), key=lambda entry: entry[1])
    if any(a[2] >= b[1] for a, b in zip(ordered, ordered[1:])):
        raise ValueError("Overlapping partitions")
    if partitions.get("linux_root") != (34, 76197882, 128626681, ROOT_GUID):
        raise ValueError("Dedicated Linux partition does not match the existing layout")
    if partitions.get("userdata", (0, 0, 0))[2] != 76197881:
        raise ValueError("Android userdata boundary changed")
    return {"sector_bytes": SECTOR, "disk_sectors": SECTORS,
            "linux_root_bytes": 214748364800,
            "primary_sha256": hashlib.sha256(primary).hexdigest(),
            "backup_sha256": hashlib.sha256(backup).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--primary", required=True, type=Path)
    parser.add_argument("--backup", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = validate(args.primary.read_bytes(), args.backup.read_bytes())
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("Both GPT copies and the existing Android/Linux boundaries are valid")


if __name__ == "__main__":
    main()
