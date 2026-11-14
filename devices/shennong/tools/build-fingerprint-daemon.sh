#!/bin/bash
# Build in the matching Droidian arm64 snapshot, using the NDK bridge built by
# build-fingerprint-aidl.py. This preserves the upstream native settings API.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
bridge=$(realpath "${1:?usage: build-fingerprint-daemon.sh libbiometry_fp_aidl.so}")
out=${SHENNONG_FP_OUT:-$repo/out/shennong/fingerprint-packages}
cache=${SHENNONG_FP_CACHE:-$repo/out/shennong/fingerprint-source-cache}
revision=1f6d7392fa6b36ec8e7e0a28afee52a6f7c23d22
version=6+git20240911202627.1f6d739.next.production+shennong3
[[ $(dpkg --print-architecture) == arm64 && -s $bridge ]]
file "$bridge" | grep -q 'ELF 64-bit LSB shared object, ARM aarch64'
mkdir -p "$out" "$cache"
if [[ ! -d $cache/source/.git ]]; then
    git init -q "$cache/source"
    git -C "$cache/source" remote add origin https://github.com/droidian/droidian-fpd.git
fi
git -C "$cache/source" cat-file -e "$revision^{commit}" 2>/dev/null ||
    git -C "$cache/source" fetch --depth 1 origin "$revision"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/source"
git -C "$cache/source" archive "$revision" | tar -xf - -C "$work/source"
for change in "$here/../patches/droidian-fpd/"*.patch; do
    patch -d "$work/source" -p1 < "$change"
done
install -D -m644 "$bridge" "$work/source/device/libbiometry_fp_aidl.so"
printf 'device/libbiometry_fp_aidl.so usr/lib/droidian-fpd\n' \
    > "$work/source/debian/droidian-fpd.install"
mkdir -p "$work/source/device/fpd-unlockd.service.d"
cat > "$work/source/device/fpd-unlockd.service.d/50-shennong-aidl.conf" <<'UNIT'
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/binder-wait -d /dev/binder android.hardware.biometrics.fingerprint.IFingerprint/default
UNIT
printf 'device/fpd-unlockd.service.d usr/lib/systemd/user\n' \
    >> "$work/source/debian/droidian-fpd.install"
# The bridge is loaded by Bionic through libhybris. Its Android libc/Binder
# dependencies belong to the private Android image, not Debian's glibc ABI.
printf '\noverride_dh_shlibdeps:\n\tdh_shlibdeps -Xlibbiometry_fp_aidl.so\n' \
    >> "$work/source/debian/rules"
{
    printf 'droidian-fpd (%s) unstable; urgency=medium\n\n' "$version"
    printf '  * Connect native Droidian fingerprint support to the stock AIDL HAL.\n'
    printf '  * Isolate Linux templates and marshal Binder callbacks to the Qt event loop.\n\n'
    printf ' -- Ning <hwn123123@users.noreply.github.com>  Sat, 14 Nov 2026 17:00:00 +0800\n\n'
    cat "$work/source/debian/changelog"
} > "$work/changelog"
mv "$work/changelog" "$work/source/debian/changelog"
(
    cd "$work/source"
    export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
    dpkg-checkbuilddeps
    dpkg-buildpackage -b --no-sign -j"$(nproc)"
)
cp "$work/droidian-fpd_${version}_arm64.deb" "$out/"
(cd "$out" && sha256sum ./*.deb > SHA256SUMS)
