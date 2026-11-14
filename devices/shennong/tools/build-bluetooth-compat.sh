#!/bin/bash
# Build the unmodified native VHCI module against the running kernel ABI.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
build="$repo/out/shennong/kernel-display-build"
source_dir="$repo/out/shennong/kernel-source"
out="$repo/out/shennong/bluetooth-compat-build"
release=6.1.138-android14-11-g0c3d559bcd85-ab14529422
[[ $(uname -m) == aarch64 && $(uname -s) == Linux ]]
[[ $(cat "$build/include/config/kernel.release") == "$release" ]]
[[ $(sha256sum "$source_dir/drivers/bluetooth/hci_vhci.c" | cut -d ' ' -f1) == fce501f239fc0417df50d5ab335ed2a00fbd8c3cf493938d8c1c6c7dc85b4207 ]]
mkdir -p "$out"
cp "$source_dir/drivers/bluetooth/hci_vhci.c" "$out/"
printf 'obj-m := hci_vhci.o\n' > "$out/Makefile"
make -C "$source_dir" O="$build" ARCH=arm64 LLVM=/usr/lib/llvm-17/bin/ \
    M="$out" LOCALVERSION= -j"$(nproc)" modules
[[ $(modinfo -F vermagic "$out/hci_vhci.ko" | cut -d ' ' -f1) == "$release" ]]
[[ $(modinfo -F depends "$out/hci_vhci.ko") == bluetooth ]]
(cd "$out" && sha256sum hci_vhci.ko > SHA256SUMS)
