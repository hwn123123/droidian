#!/usr/bin/env python3
"""Compare stock ARM64 module symbol CRCs with a rebuilt kernel's Module.symvers."""
import argparse
import json
import struct
from pathlib import Path


def module_info(path):
    data = path.read_bytes()
    if data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != 183:
        raise ValueError(f"Expected an uncompressed little-endian ARM64 module: {path}")
    offset = struct.unpack_from("<Q", data, 40)[0]
    stride, count, names_index = struct.unpack_from("<HHH", data, 58)
    if stride != 64 or count == 0 or names_index >= count or offset + stride * count > len(data):
        raise ValueError(f"Unsupported ELF section table: {path}")
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, offset + i * stride)
                for i in range(count)]

    def contents(section):
        start, size = section[4:6]
        if start + size > len(data):
            raise ValueError(f"Truncated ELF section: {path}")
        return data[start:start + size]

    names = contents(sections[names_index])
    by_name = {}
    for section in sections:
        start = section[0]
        end = names.find(b"\0", start)
        if start >= len(names) or end < 0:
            raise ValueError(f"Invalid ELF section name: {path}")
        by_name[names[start:end].decode()] = section
    if "__versions" not in by_name:
        raise ValueError(f"Module does not carry symbol versions: {path}")
    versions = contents(by_name["__versions"])
    if len(versions) % 64:
        raise ValueError(f"Unexpected modversion entry size: {path}")
    imports = {}
    for offset in range(0, len(versions), 64):
        crc = struct.unpack_from("<Q", versions, offset)[0] & 0xffffffff
        name = versions[offset + 8:offset + 64].split(b"\0", 1)[0].decode()
        imports[name] = crc
    exports = set()
    for name in by_name:
        if name.startswith(("___ksymtab+", "___ksymtab_gpl+")):
            exports.add(name.split("+", 1)[1])
    if ".strtab" in by_name:
        for name in contents(by_name[".strtab"]).split(b"\0"):
            if name.startswith(b"__ksymtab_"):
                exports.add(name[len(b"__ksymtab_"):].decode())
    modinfo = contents(by_name[".modinfo"]) if ".modinfo" in by_name else b""
    vermagic = next((v.split(b"=", 1)[1].decode() for v in modinfo.split(b"\0")
                     if v.startswith(b"vermagic=")), "")
    return imports, exports, vermagic


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--symvers", type=Path, required=True)
    parser.add_argument("--modules", type=Path, required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--kernel-module", type=Path, required=True,
                        help="A module built together with the new kernel (for vermagic features)")
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()
    symbols = {}
    for line in args.symvers.read_text().splitlines():
        values = line.split()
        if len(values) >= 3:
            symbols[values[1]] = int(values[0], 16)
    if not symbols:
        raise SystemExit("No kernel symbols found")
    _, _, kernel_magic = module_info(args.kernel_module)
    if not kernel_magic or kernel_magic.split()[0] != args.release:
        raise SystemExit("The new kernel module does not match the requested kernel release")
    paths = sorted(args.modules.rglob("*.ko"))
    if not paths:
        raise SystemExit("No stock modules found")
    modules = [(p, *module_info(p)) for p in paths]
    vendor_exports = set().union(*(exports for _, _, exports, _ in modules))
    mismatches, unresolved, releases, magic_mismatches = [], [], [], []
    checked = 0
    for path, imports, _, vermagic in modules:
        name = str(path.relative_to(args.modules))
        if not vermagic or vermagic.split()[0] != args.release:
            releases.append({"module": name, "vermagic": vermagic})
        # Linux 6.1 same_magic() ignores the release token for versioned
        # modules. Keep that difference in the report, but validate the
        # remaining features and the actual symbol CRCs, as the loader does.
        if vermagic.partition(" ")[2] != kernel_magic.partition(" ")[2]:
            magic_mismatches.append({"module": name, "vermagic": vermagic,
                                     "expected": kernel_magic})
        for symbol, crc in imports.items():
            if symbol in symbols:
                checked += 1
                if symbols[symbol] != crc:
                    mismatches.append({"module": name, "symbol": symbol,
                                       "stock_crc": f"0x{crc:08x}",
                                       "new_crc": f"0x{symbols[symbol]:08x}"})
            elif symbol not in vendor_exports:
                unresolved.append({"module": name, "symbol": symbol})
    report = {"modules": len(modules), "checked_kernel_imports": checked,
              "crc_mismatches": mismatches, "unresolved_imports": unresolved,
              "release_differences": releases, "vermagic_mismatches": magic_mismatches,
              "kernel_abi_matches": not (mismatches or unresolved or magic_mismatches)}
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Modules: {len(modules)}; kernel imports checked: {checked}; "
          f"CRC mismatches: {len(mismatches)}; unresolved: {len(unresolved)}; "
          f"vermagic feature mismatches: {len(magic_mismatches)}")
    print(f"Report: {args.json}")
    print("This checks the kernel/module ABI only; a match still needs an actual boot test.")
    return 0 if report["kernel_abi_matches"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
