#!/bin/bash
# Include the native settings repair in every newly assembled device image.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-control-center.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
out="$repo/out/shennong/settings-packages"
version=50.1-1~git20260527223353.feb760d.next.gnome.50+shennong3
archives=("gnome-control-center_${version}_arm64.deb" "gnome-control-center-data_${version}_all.deb")
for archive in "${archives[@]}"; do
    [[ -s $out/$archive ]] || { echo 'Build tools/build-control-center.sh first.' >&2; exit 1; }
done
(cd "$out" && sha256sum --check SHA256SUMS)
stage=$(mktemp -d "$root/tmp/shennong-settings.XXXXXX")
trap 'rm -rf "$stage"' EXIT
for archive in "${archives[@]}"; do
    install -m644 "$out/$archive" "$stage/$archive"
done
chroot "$root" dpkg -i \
    "${stage#"$root"}/${archives[0]}" "${stage#"$root"}/${archives[1]}"
