#!/bin/bash
# Offline image preparation: select the existing Composer process only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(realpath "${1:?usage: sudo install-drm-compat.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
work=$(mktemp -d)
cleanup() {
    if mountpoint -q "$work/vendor"; then umount "$work/vendor" || return 1; fi
    rm -r "$work"
}
trap cleanup EXIT
mkdir "$work/vendor"
mount -o loop,ro,nosuid,nodev "$root/opt/shennong/vendor/vendor.img" "$work/vendor"
python3 "$here/stage-display-service-policy.py" --source "$work/vendor/etc/init" \
    --output "$root/usr/lib/droid-vendor-overlay/etc/init"
bash "$here/build-drm-compat.sh" "$work/build"
install -D -m644 "$work/build/libshennong-drm-compat.so" \
    "$root/usr/lib/droid-vendor-overlay/lib64/libshennong-drm-compat.so"
