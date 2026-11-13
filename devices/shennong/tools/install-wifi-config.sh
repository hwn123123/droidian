#!/bin/bash
# Build-time only: derive configuration from the captured read-only vendor image.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(realpath "${1:?usage: sudo install-wifi-config.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
work=$(mktemp -d)
cleanup() {
    if mountpoint -q "$work/vendor"; then
        umount "$work/vendor" || return 1
    fi
    rm -r "$work"
}
trap cleanup EXIT
mkdir "$work/vendor"
mount -o loop,ro,nosuid,nodev "$root/opt/shennong/vendor/vendor.img" "$work/vendor"
python3 "$here/stage-wifi-config.py" \
    --source "$work/vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini" \
    --output "$root/usr/lib/firmware/shennong/wlan/qca_cld/kiwi_v2/WCNSS_qcom_cfg.ini"
