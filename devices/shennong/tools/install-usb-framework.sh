#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(realpath "${1:?usage: sudo install-usb-framework.sh DEVICE_ROOT}")
[ "$EUID" = 0 ] && [ "$root" != / ]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
work=$(mktemp -d)
cleanup() {
    if mountpoint -q "$work/android"; then
        for attempt in {1..10}; do
            if umount "$work/android"; then break; fi
            sleep 0.2
        done
        mountpoint -q "$work/android" && return 1
    fi
    rm -r "$work"
}
trap cleanup EXIT
mkdir "$work/android"
mount -o loop,ro,nosuid,nodev "$root/var/lib/lxc/android/android-rootfs.img" "$work/android"
bash "$here/build-usb-framework.sh" "$work/android/system/lib64" "$work/build"
install -D -m 755 "$work/build/shennong-usb-framework" \
    "$root/usr/lib/droid-system-overlay/bin/shennong-usb-framework"
