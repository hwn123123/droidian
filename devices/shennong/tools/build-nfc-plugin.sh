#!/bin/bash
# Build upstream's AIDL transport using Droidian's native packaging.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
cache="$repo/out/shennong/log-audit"
out="$repo/out/shennong/nfc-packages"
revision=ee270922a39d3730226936d7e78896dd508400be
packaging=81e7c482b06914a2f610b409b602544335cfc882
version=1.2.2-1+shennong1
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
archive nfcd-binder-plugin https://github.com/mer-hybris/nfcd-binder-plugin.git "$revision" "$work/source"
archive nfcd-binder-droidian https://github.com/droidian/nfcd-binder-plugin.git "$packaging" "$work/packaging"
cp -a "$work/packaging/debian" "$work/source/"
# Keep normal dependency generation for the newer upstream plugin.
sed -i '/^override_dh_shlibdeps:$/d; /^override_dh_makeshlibs:$/d' "$work/source/debian/rules"
cat > "$work/source/debian/changelog" <<CHANGELOG
nfcd-binder-plugin ($version) unstable; urgency=medium

  * Use upstream AIDL NFC transport with the stock shennong HAL.

 -- Ning <hwn123123@users.noreply.github.com>  Sat, 14 Nov 2026 13:00:00 +0800
CHANGELOG
(
    cd "$work/source"
    export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
    dpkg-checkbuilddeps
    dpkg-buildpackage -b --no-sign -j"$(nproc)"
)
cp "$work/nfcd-binder-plugin_${version}_arm64.deb" "$out/"
(cd "$out" && sha256sum ./*.deb > SHA256SUMS)
