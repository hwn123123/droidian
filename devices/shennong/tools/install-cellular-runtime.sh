#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-cellular-runtime.sh DEVICE_ROOT}")
inputs=${SHENNONG_CELLULAR_RUNTIME:-$repo/out/shennong/private-cellular}
[ "$EUID" = 0 ] && [ "$root" != / ]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
destination="$root/usr/lib/droid-vendor-overlay/lib64/shennong-cellular"
python3 - "$inputs" "$destination" <<'PY'
import hashlib, json, shutil, sys
from pathlib import Path
inputs, destination = map(Path, sys.argv[1:])
manifest = json.loads((inputs / 'manifest.json').read_text())
destination.mkdir(parents=True, exist_ok=True)
for name in ('libcom.android.tethering.connectivity_native.so',
             'libcom.android.tethering.dns_helper.so', 'libc++.so'):
    source = inputs / name
    data = source.read_bytes()
    info = manifest[name]
    if len(data) != info['size'] or hashlib.sha256(data).hexdigest() != info['sha256']:
        raise SystemExit(f'Stock NICM dependency changed: {name}')
    if data[:5] != b'\x7fELF\x02' or data[18:20] != b'\xb7\x00':
        raise SystemExit(f'Not an arm64 ELF library: {name}')
    shutil.copyfile(source, destination / name)
    (destination / name).chmod(0o644)
PY
"${SHENNONG_ANDROID_CC:-clang}" --target=aarch64-linux-android34 -fuse-ld=lld \
    -nostdlib -shared -fPIC -fno-stack-protector -O2 -Wall -Wextra -Werror \
    -Wl,-soname,libshennong-nicm-linux.so \
    "$here/../compat/nicm-linux.c" -o "$destination/libshennong-nicm-linux.so"
chmod 644 "$destination/libshennong-nicm-linux.so"
