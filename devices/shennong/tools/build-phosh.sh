#!/bin/bash
# Build inside the matching arm64 Droidian snapshot (a build chroot is fine).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=${SHENNONG_UI_OUT:-$repo/out/shennong/ui-packages}
cache=${SHENNONG_UI_CACHE:-$repo/out/shennong/ui-source-cache}
revision=bee1861911b0cf75f50ab00cea5a84ed98d9c32f
version=0.55.0+git20260824233009.bee1861.next.phosh.0.55+shennong3
[[ $(dpkg --print-architecture) == arm64 ]]
mkdir -p "$cache" "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

archive_source() {
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

archive_source phosh https://github.com/droidian/phosh.git "$revision" "$work/source"
archive_source gvc https://github.com/droidian/libgnome-volume-control.git \
    40aea7b7d3c00a801c8d72320d33203163c3ba0f "$work/source/subprojects/gvc"
archive_source libcall-ui https://gitlab.gnome.org/World/Phosh/libcall-ui.git \
    7389b4ae90e101620ef8e790e76a98e434bd920c "$work/source/subprojects/libcall-ui"
patch -d "$work/source" -p1 < "$here/../patches/phosh/0001-native-phone-home.patch"
{
    printf 'phosh (%s) unstable; urgency=medium\n\n' "$version"
    printf '  * Add native home, fixed favorites dock and touch app ordering.\n\n'
    printf ' -- Ning <hwn123123@users.noreply.github.com>  Fri, 13 Nov 2026 19:00:00 +0800\n\n'
    cat "$work/source/debian/changelog"
} > "$work/changelog"
mv "$work/changelog" "$work/source/debian/changelog"
(
    cd "$work/source"
    export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
    export DEB_BUILD_PROFILES='nodoc nocheck'
    dpkg-checkbuilddeps -Pnodoc,nocheck
    dpkg-buildpackage -b --no-sign -Pnodoc,nocheck -j"$(nproc)"
)
cp "$work/phosh_${version}_arm64.deb" "$work/phosh-common_${version}_all.deb" \
   "$work/phosh-plugins_${version}_arm64.deb" \
   "$work/phosh-mobile-tweaks_${version}_all.deb" "$out/"
(cd "$out" && sha256sum ./*.deb > SHA256SUMS)
