#!/bin/bash
# Offline image preparation only; captured rc files remain private build inputs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(realpath "${1:?usage: sudo install-rpc-service-policy.sh DEVICE_ROOT}")
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
python3 "$here/stage-rpc-service-policy.py" --source "$work/vendor/etc/init" \
    --output "$root/usr/lib/droid-vendor-overlay/etc/init"
