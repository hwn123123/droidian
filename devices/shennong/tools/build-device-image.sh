#!/usr/bin/env bash
# Create the exact dedicated-partition image offline.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../../.." && pwd -P)
[[ $EUID == 0 && $# == 2 ]] || { echo "usage: sudo $0 ROOTFS.tar.gz SSH_PUBLIC_KEY" >&2; exit 2; }
archive=$(realpath "$1")
key=$(realpath "$2")
out="$repo/out/shennong/device-image"
[[ -s $archive && ! -e $out ]] || { echo 'Missing rootfs or output already exists' >&2; exit 1; }
mkdir -p "$out/root"
raw="$out/linux_root.raw"
size=214748364800
truncate -s "$size" "$raw"
mke2fs -q -t ext4 -F -L linux_root -m 0 -I 256 -N 524288 "$raw"
cleanup() { mountpoint -q "$out/root" && umount "$out/root" || true; }
trap cleanup EXIT
mount -o loop,rw,noatime "$raw" "$out/root"
tar --numeric-owner --xattrs --acls -xzpf "$archive" -C "$out/root"
bash "$here/prepare-device-root.sh" "$out/root" "$key"
sync "$out/root"
umount "$out/root"
e2fsck -f -p "$raw"
# The raw file keeps the full partition geometry but is sparse on the host.
# Skip holes instead of reading 200 GiB of unwritten blocks.
img2simg -s "$raw" "$out/linux_root-droidian.simg"
(cd "$out" && sha256sum linux_root-droidian.simg > SHA256SUMS)
echo "Device image built at $out/linux_root-droidian.simg (200 GiB ext4 geometry)."
