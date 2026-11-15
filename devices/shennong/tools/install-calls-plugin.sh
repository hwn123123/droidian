#!/bin/bash
# Install the native provider package during offline device image assembly.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-calls-plugin.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
out="$repo/out/shennong/calls-packages"
archive=gnome-calls_51.1-1+shennong3_arm64.deb
[[ -s $out/$archive ]] || {
    echo 'Build the native Calls provider with tools/build-calls-plugin.sh first.' >&2
    exit 1
}
(cd "$out" && sha256sum --check SHA256SUMS)
install -m644 "$out/$archive" "$root/tmp/shennong-calls.deb"
chroot "$root" dpkg -i /tmp/shennong-calls.deb
rm "$root/tmp/shennong-calls.deb"
