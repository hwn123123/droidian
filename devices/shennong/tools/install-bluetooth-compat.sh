#!/bin/bash
# Offline image preparation only; service activation remains with systemd.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-bluetooth-compat.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
release=6.1.138-android14-11-g0c3d559bcd85-ab14529422
bash "$here/build-bluetooth-compat.sh"
install -D -m644 "$repo/out/shennong/bluetooth-compat-build/hci_vhci.ko" \
    "$root/lib/modules/$release/kernel/drivers/bluetooth/hci_vhci.ko"
depmod -b "$root" "$release"
