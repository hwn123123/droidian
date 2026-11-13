#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the GPL handoff against the running display kernel and stock SPF ABI.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
build="$repo/out/shennong/kernel-display-build"
source_dir="$repo/out/shennong/kernel-source"
stock="$repo/out/shennong/stock-modules/vendor_dlkm/lib/modules/spf_core_dlkm.ko"
out="$repo/out/shennong/audio-compat-build"
release=6.1.138-android14-11-g0c3d559bcd85-ab14529422
[[ $(uname -m) == aarch64 && $(uname -s) == Linux ]]
[[ $(cat "$build/include/config/kernel.release") == "$release" ]]
[[ $(sha256sum "$stock" | cut -d ' ' -f1) == 47e09e0bc78752d0a6624443daed09eafa57d30693e2343695891aa6aa875e7c ]]
mkdir -p "$out"
cp "$here/../compat/audio/Makefile" "$here/../compat/audio/shennong_audio_compat.c" "$out/"
# Exported GPL CRC from the hash-checked SPF module's __kcrctab_gpl section.
printf '0x8d8c0146\tspf_core_is_apm_ready\tspf_core_dlkm\tEXPORT_SYMBOL_GPL\t\n' > "$out/stock.symvers"
make -C "$source_dir" O="$build" ARCH=arm64 LLVM=/usr/lib/llvm-17/bin/ \
    M="$out" KBUILD_EXTRA_SYMBOLS="$out/stock.symvers" LOCALVERSION= \
    -j"$(nproc)" modules
[[ $(modinfo -F vermagic "$out/shennong_audio_compat.ko" | cut -d ' ' -f1) == "$release" ]]
modprobe --dump-modversions "$out/shennong_audio_compat.ko" |
    grep -Eq '^0x8d8c0146[[:space:]]+spf_core_is_apm_ready$'
(cd "$out" && sha256sum shennong_audio_compat.ko > SHA256SUMS)
