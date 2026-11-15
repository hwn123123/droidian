#!/bin/bash
# Offline image integration through oFono's native Binder extension setting.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-qti-ims-plugin.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
out="$repo/out/shennong/qti-ims-packages"
archive=ofono-binder-plugin-ext-qti_1.0+git20261112.71b9d41+shennong2_arm64.deb
[[ -s $out/$archive ]] || {
    echo 'Build the Qualcomm IMS extension with tools/build-qti-ims-plugin.sh first.' >&2
    exit 1
}
(cd "$out" && sha256sum --check SHA256SUMS)
install -m644 "$out/$archive" "$root/tmp/shennong-qti-ims.deb"
chroot "$root" dpkg -i /tmp/shennong-qti-ims.deb
rm "$root/tmp/shennong-qti-ims.deb"
