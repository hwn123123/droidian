#!/bin/bash
# Build the existing native settings app in the matching arm64 Droidian snapshot.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=${SHENNONG_SETTINGS_OUT:-$repo/out/shennong/settings-packages}
cache=${SHENNONG_SETTINGS_CACHE:-$repo/out/shennong/settings-source-cache}
revision=feb760d44e450f8284059ae1f1a5e4831c710c64
version=1:50.1-1~git20260527223353.feb760d.next.gnome.50+shennong4
archive_version=${version#*:}
[[ $(dpkg --print-architecture) == arm64 ]]
mkdir -p "$out" "$cache"
if [[ ! -d $cache/source/.git ]]; then
    git init -q "$cache/source"
    git -C "$cache/source" remote add origin https://github.com/droidian/gnome-control-center.git
fi
git -C "$cache/source" cat-file -e "$revision^{commit}" 2>/dev/null ||
    git -C "$cache/source" fetch --depth 1 origin "$revision"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/source"
git -C "$cache/source" archive "$revision" | tar -xf - -C "$work/source"
for change in "$here/../patches/gnome-control-center/"*.patch; do
    patch -d "$work/source" -p1 < "$change"
done
{
    printf 'gnome-control-center (%s) unstable; urgency=medium\n\n' "$version"
    printf '  * Complete native fingerprint enrollment, result feedback and retries.\n'
    printf '  * Translate fingerprint and NFC device panels into Simplified Chinese.\n\n'
    printf ' -- Ning <hwn123123@users.noreply.github.com>  Sat, 14 Nov 2026 23:40:00 +0800\n\n'
    cat "$work/source/debian/changelog"
} > "$work/changelog"
mv "$work/changelog" "$work/source/debian/changelog"
(
    cd "$work/source"
    export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
    dpkg-checkbuilddeps
    dpkg-buildpackage -b --no-sign -j"$(nproc)"
)
cp "$work/gnome-control-center_${archive_version}_arm64.deb" \
   "$work/gnome-control-center-data_${archive_version}_all.deb" "$out/"
(cd "$out" && sha256sum ./*.deb > SHA256SUMS)
