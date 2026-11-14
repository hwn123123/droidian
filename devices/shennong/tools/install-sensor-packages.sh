#!/bin/bash
# Install the native sensor transport into an offline device root.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-sensor-packages.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
out="$repo/out/shennong/sensor-packages"
version=0.15.2-1+shennong1
archives=()
for name in sensorfw-qt6 libsensorfw-qt6-plugins libsensorfw-qt6-hybris libsensorfw-qt6-configs; do
    archive="${name}_${version}_arm64.deb"
    [[ -s $out/$archive ]] || {
        echo 'Build the native sensor packages with tools/build-sensorfw.sh first.' >&2
        exit 1
    }
    archives+=("$archive")
done
for name in sensorfw-qt5 libsensorfw-qt5-plugins libsensorfw-qt5-hybris libsensorfw-qt5-configs; do
    archive="${name}_${version}_all.deb"
    [[ -s $out/$archive ]] || { echo "Missing Qt5 transitional package: $archive" >&2; exit 1; }
    archives+=("$archive")
done
proxy=hadess-sensorfw-proxy_0.2.1+git20250215143745.309fff0.next.production+shennong2_arm64.deb
[[ -s $out/$proxy ]] || {
    echo 'Build the native sensor proxy with tools/build-sensor-proxy.sh first.' >&2
    exit 1
}
archives+=("$proxy")
(cd "$out" && sha256sum --check SHA256SUMS)
stage="$root/tmp/shennong-sensor-packages"
mkdir -p "$stage"
for archive in "${archives[@]}"; do install -m644 "$out/$archive" "$stage/"; done
chroot "$root" /bin/sh -c 'dpkg -i /tmp/shennong-sensor-packages/*.deb'
rm -r "$stage"
