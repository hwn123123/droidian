#!/bin/bash
# Keep capability reporting and socket handling inside the native proxy.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
cache="$repo/out/shennong/log-audit/hadess-proxy"
out="$repo/out/shennong/sensor-packages"
revision=309fff057e3f0ebbb3c1caa8f270696ddb800fdd
version=0.2.1+git20250215143745.309fff0.next.production+shennong2
[[ $(dpkg --print-architecture) == arm64 ]]
mkdir -p "$out" "$(dirname "$cache")"
if [[ ! -d $cache/.git ]]; then
    git init -q "$cache"
    git -C "$cache" remote add origin https://github.com/droidian/hadess-sensorfw-proxy.git
fi
git -C "$cache" cat-file -e "$revision^{commit}" 2>/dev/null ||
    git -C "$cache" fetch --depth 1 origin "$revision"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/source"
git -C "$cache" archive "$revision" | tar -xf - -C "$work/source"
for change in "$here/../patches/hadess-sensorfw-proxy/"*.patch; do
    patch -d "$work/source" -p1 < "$change"
done
# No Sensorfw headers or binaries are used by this D-Bus/socket client.
sed -i '/^[[:space:]]*sensorfw-qt5,/d' "$work/source/debian/control"
sed -i 's/ --fail-missing//' "$work/source/debian/rules"
cat >> "$work/source/debian/rules" <<'RULES'

override_dh_auto_configure:
	dh_auto_configure -- -DCMAKE_POLICY_VERSION_MINIMUM=3.5

override_dh_missing:
	dh_missing --fail-missing
RULES
cat > "$work/source/debian/changelog" <<CHANGELOG
hadess-sensorfw-proxy ($version) unstable; urgency=medium

  * Reject unavailable sessions and bound fragmented sensor socket reads.

 -- Ning <hwn123123@users.noreply.github.com>  Sat, 14 Nov 2026 12:30:00 +0800
CHANGELOG
(
    cd "$work/source"
    export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
    dpkg-checkbuilddeps
    dpkg-buildpackage -b --no-sign -j"$(nproc)"
)
sensor_core="$work/source/sensorfw-core"
moc "$sensor_core/socketreader.h" -o "$work/socketreader-moc.cpp"
g++ -fPIC -pthread -UNDEBUG -I"$sensor_core" $(pkg-config --cflags Qt5Core Qt5Network) \
    "$here/../tests/test_sensor_socket.cpp" "$sensor_core/socketreader.cpp" \
    "$work/socketreader-moc.cpp" $(pkg-config --libs Qt5Core Qt5Network) \
    -o "$work/test-sensor-socket"
timeout 15 "$work/test-sensor-socket"
cp "$work/hadess-sensorfw-proxy_${version}_arm64.deb" "$out/"
(cd "$out" && sha256sum ./*.deb > SHA256SUMS)
