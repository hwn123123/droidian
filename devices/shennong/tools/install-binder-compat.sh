#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Offline image assembly: build from source against this image's Android ABI.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(realpath "${1:?usage: sudo install-binder-compat.sh DEVICE_ROOT}")
[ "$EUID" = 0 ] && [ "$root" != / ]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
work=$(mktemp -d)
cleanup() {
    if mountpoint -q "$work/android"; then
        # Loop-backed Android images may retain a short-lived kernel reference
        # after the linker exits. Never remove the directory while mounted.
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
bash "$here/build-binder-compat.sh" "$work/android" "$work/build"
install -D -m 644 "$work/build/libshennong-binder-compat.so" \
    "$root/usr/lib/droid-vendor-overlay/lib64/libshennong-binder-compat.so"
