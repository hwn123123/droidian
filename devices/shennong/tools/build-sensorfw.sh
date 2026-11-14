#!/bin/bash
# Build upstream AIDL support with Droidian's native Qt6 packaging.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
cache=${SHENNONG_SENSOR_CACHE:-$repo/out/shennong/log-audit}
out=${SHENNONG_SENSOR_OUT:-$repo/out/shennong/sensor-packages}
revision=a1af4b071b7f7de2c95233ad886c6652afbb1c6e
packaging=feafda86681933e599c742d6b6bcef0dddd0e73f
version=0.15.2-1+shennong1
[[ $(dpkg --print-architecture) == arm64 ]]
mkdir -p "$cache" "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archive() {
    local name=$1 url=$2 commit=$3 destination=$4
    if [[ ! -d $cache/$name/.git ]]; then
        git init -q "$cache/$name"
        git -C "$cache/$name" remote add origin "$url"
    fi
    git -C "$cache/$name" cat-file -e "$commit^{commit}" 2>/dev/null ||
        git -C "$cache/$name" fetch --depth 1 origin "$commit"
    mkdir -p "$destination"
    git -C "$cache/$name" archive "$commit" | tar -xf - -C "$destination"
}
archive sensorfw https://github.com/sailfishos/sensorfw.git "$revision" "$work/source"
archive sensorfw-droidian https://github.com/droidian/sensorfw.git "$packaging" "$work/packaging"
rm -r "$work/source/debian"
cp -a "$work/packaging/debian" "$work/source/debian"
# Keep Droidian's service ordering and explicit hybris configuration. These
# packaging files are absent/different in the Sailfish upstream tree.
cp "$work/packaging/rpm/sensorfwd.service" \
   "$work/packaging/rpm/sensorfwd-hybris-dropin.conf" "$work/source/rpm/"
# The upstream daemon no longer uses Droidian's deviceinfo extension. Docs
# remain optional build dependencies, as no documentation is generated here.
sed -i -e '/^[[:space:]]*libdeviceinfo-dev,/d' \
    -e 's/doxygen,/doxygen <!nodoc>,/' \
    -e 's/graphviz,/graphviz <!nodoc>,/' "$work/source/debian/control"
{
    printf 'sensorfw-qt6 (%s) unstable; urgency=medium\n\n' "$version"
    printf '  * Use upstream AIDL sensor transport with native Droidian Qt6 packages.\n\n'
    printf ' -- Ning <hwn123123@users.noreply.github.com>  Sat, 14 Nov 2026 12:00:00 +0800\n\n'
    # Droidian's CI generates changelog; its source branch has no such file.
} > "$work/changelog"
mv "$work/changelog" "$work/source/debian/changelog"
(
    cd "$work/source"
    export DEB_BUILD_OPTIONS="nocheck nodocs parallel=$(nproc)"
    dpkg-checkbuilddeps -Pnodoc,nocheck
    dpkg-buildpackage -b --no-sign -Pnodoc,nocheck -j"$(nproc)"
)
for name in sensorfw-qt6 libsensorfw-qt6-plugins libsensorfw-qt6-hybris libsensorfw-qt6-configs; do
    cp "$work/${name}_${version}_arm64.deb" "$out/"
done
for name in sensorfw-qt5 libsensorfw-qt5-plugins libsensorfw-qt5-hybris libsensorfw-qt5-configs; do
    cp "$work/${name}_${version}_all.deb" "$out/"
done
(cd "$out" && sha256sum ./*.deb > SHA256SUMS)
