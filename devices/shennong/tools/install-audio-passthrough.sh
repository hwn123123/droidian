#!/bin/bash
# Offline integration of the native modem-to-audio bridge.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-audio-passthrough.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
out="$repo/out/shennong/audio-passthrough-packages"
archive=audiosystem-passthrough_1.3.0-1+droidian1+git20240519112654.f49813c.next.production+shennong2_arm64.deb
[[ -s $out/$archive ]] || {
    echo 'Build the native audio bridge with tools/build-audio-passthrough.sh first.' >&2
    exit 1
}
(cd "$out" && sha256sum --check SHA256SUMS)
install -m644 "$out/$archive" "$root/tmp/shennong-audio-passthrough.deb"
chroot "$root" dpkg -i /tmp/shennong-audio-passthrough.deb
rm "$root/tmp/shennong-audio-passthrough.deb"
# module-droid-hidl already supervises this helper. Avoid a second client
# replacing the per-slot callback from an independently started user unit.
systemctl --root="$root" --global disable audiosystem-passthrough.service
