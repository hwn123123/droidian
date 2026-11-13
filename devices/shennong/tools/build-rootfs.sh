#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../../.." && pwd -P)
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || {
    echo 'Build this recipe in the arm64 Ubuntu/Debian VM.' >&2
    exit 1
}
[[ $EUID == 0 ]] || { echo 'debos needs root; run with sudo.' >&2; exit 1; }
for tool in debos dpkg-buildpackage gpgv python3; do command -v "$tool" >/dev/null; done
out="$repo/out/shennong"
mkdir -p "$out"

python3 "$here/fetch-inputs.py" --output "$out/inputs"
work=$(mktemp -d "$out/adaptation-build.XXXXXX")
cp -a "$here/../packages/adaptation-xiaomi-shennong" "$work/source"
chmod +x "$work/source/debian/rules"
(
    cd "$work/source"
    dpkg-buildpackage --no-sign -b
)
overlay="$out/rootfs-overlay/var/cache/shennong-adaptation"
mkdir -p "$overlay"
# Stage only this build's packages; mixed versions break the exact dependency.
rm -f "$overlay"/adaptation-xiaomi-shennong_*.deb \
    "$overlay"/adaptation-xiaomi-shennong-configs_*.deb
cp "$work/"*.deb "$overlay/"
cd "$repo"
debos --disable-fakemachine --artifactdir="$out" devices/shennong/rootfs.yaml
sha256sum "$out/droidian-shennong-rootfs.tar.gz" > "$out/rootfs.sha256"
