#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
libs=${1:?usage: build-usb-framework.sh ANDROID_SYSTEM_LIB64 OUTPUT_DIR}
out=${2:?usage: build-usb-framework.sh ANDROID_SYSTEM_LIB64 OUTPUT_DIR}
ndk=${ANDROID_NDK_ROOT:?Set ANDROID_NDK_ROOT to an Android NDK installation}
case $(uname -s) in
    Darwin) tag=darwin-x86_64 ;;
    Linux) tag=linux-x86_64 ;;
    *) echo 'Unsupported NDK host' >&2; exit 1 ;;
esac
tc="$ndk/toolchains/llvm/prebuilt/$tag"
compiler="$tc/bin/clang++"
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
    # The NDK sysroot/CRT are architecture-independent build inputs. An arm64
    # builder can use its native Clang without running the x86 NDK frontend.
    compiler=clang++
fi
compiler=${SHENNONG_ANDROID_CXX:-$compiler}
resource=$(find "$tc/lib/clang" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
[ -s "$libs/libbinder_ndk.so" ]
mkdir -p "$out"
"$compiler" --target=aarch64-linux-android34 --sysroot="$tc/sysroot" \
    -resource-dir "$resource" -rtlib=compiler-rt -unwindlib=libunwind \
    -std=c++17 -stdlib=libc++ -O2 -Wall -Wextra -Werror -static-libstdc++ \
    -fPIE -pie -Wl,-z,relro,-z,now \
    -I "$here/../compat/binder-headers/include_platform" \
    -I "$here/../compat/binder-headers/include_cpp" \
    "$here/../compat/usb-framework.cpp" "$libs/libbinder_ndk.so" \
    -o "$out/shennong-usb-framework"
