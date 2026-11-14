#!/bin/bash
# Install the native fingerprint transport into the offline device image.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-fingerprint-packages.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
out="$repo/out/shennong/fingerprint-packages"
archive=droidian-fpd_6+git20240911202627.1f6d739.next.production+shennong3_arm64.deb
[[ -s $out/$archive ]] || {
    echo 'Build the AIDL bridge and native fingerprint package first.' >&2
    exit 1
}
(cd "$out" && sha256sum --check SHA256SUMS)
install -m644 "$out/$archive" "$root/tmp/shennong-fingerprint.deb"
chroot "$root" dpkg -i /tmp/shennong-fingerprint.deb
rm "$root/tmp/shennong-fingerprint.deb"
