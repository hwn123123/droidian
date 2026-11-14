#!/bin/bash
# Build a scoped Bionic preload; the original Composer and libdrm stay intact.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build-drm-compat.sh OUTPUT_DIR}
ndk=${ANDROID_NDK_ROOT:?Set ANDROID_NDK_ROOT to an Android NDK installation}
case $(uname -s) in
    Darwin) tag=darwin-x86_64 ;;
    Linux) tag=linux-x86_64 ;;
    *) exit 1 ;;
esac
tc="$ndk/toolchains/llvm/prebuilt/$tag"
compiler="$tc/bin/clang"
if [[ $(uname -s) == Linux && $(uname -m) == aarch64 ]]; then compiler=clang; fi
resource=$(find "$tc/lib/clang" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
mkdir -p "$out"
"$compiler" --target=aarch64-linux-android34 --sysroot="$tc/sysroot" \
    -resource-dir "$resource" -rtlib=compiler-rt -unwindlib=libunwind \
    -fuse-ld=lld -shared -fPIC -std=c11 -O2 -Wall -Wextra -Werror \
    -Wl,-z,defs,-z,relro,-z,now -Wl,-soname,libshennong-drm-compat.so \
    "$here/../compat/drm-shared-master.c" -ldl -o "$out/libshennong-drm-compat.so"
