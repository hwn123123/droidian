#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build against the captured Android 14 runtime, never the Linux host libc.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${1:?usage: build-binder-compat.sh ANDROID_ROOT OUTPUT_DIR}
out=${2:?usage: build-binder-compat.sh ANDROID_ROOT OUTPUT_DIR}
mkdir -p "$out"
for lib in libc libdl; do
    [ -s "$root/system/lib64/bootstrap/$lib.so" ]
done
clang --target=aarch64-linux-android34 -fuse-ld=lld -nostdlib -shared -fPIC \
    -O2 -Wall -Wextra -Werror -Wl,-z,defs,-z,relro,-z,now \
    -Wl,-soname,libshennong-binder-compat.so \
    "$here/../compat/binder-no-secctx.c" \
    "$root/system/lib64/bootstrap/libc.so" \
    "$root/system/lib64/bootstrap/libdl.so" \
    -o "$out/libshennong-binder-compat.so"
readelf -h "$out/libshennong-binder-compat.so" | grep -q 'Machine:.*AArch64'
readelf -d "$out/libshennong-binder-compat.so" | grep NEEDED
