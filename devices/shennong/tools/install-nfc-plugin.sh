#!/bin/bash
# Offline image assembly; systemd remains the owner of NFC service startup.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-nfc-plugin.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
out="$repo/out/shennong/nfc-packages"
archive=nfcd-binder-plugin_1.2.2-1+shennong1_arm64.deb
[[ -s $out/$archive ]] || {
    echo 'Build the AIDL NFC plugin with tools/build-nfc-plugin.sh first.' >&2
    exit 1
}
(cd "$out" && sha256sum --check SHA256SUMS)
install -m644 "$out/$archive" "$root/tmp/shennong-nfc-plugin.deb"
chroot "$root" dpkg -i /tmp/shennong-nfc-plugin.deb
rm "$root/tmp/shennong-nfc-plugin.deb"
