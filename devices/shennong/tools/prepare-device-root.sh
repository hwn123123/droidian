#!/usr/bin/env bash
# Finish an offline Droidian root for this device, including private local inputs.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../../.." && pwd -P)
[[ $EUID == 0 && $# == 2 ]] || { echo "usage: sudo $0 ROOT_DIR SSH_PUBLIC_KEY" >&2; exit 2; }
root=$(realpath "$1")
key=$(realpath "$2")
[[ $root != / && -s $key && -f $root/etc/droidian/shennong-build ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
rm -f "$root/etc/apt/apt.conf.d/99-shennong-build-proxy"
build="$repo/out/shennong/kernel-display-build"
private="$repo/out/shennong/private-vendor"
stock_modules="$repo/out/shennong/stock-modules"
release=6.1.138-android14-11-g0c3d559bcd85-ab14529422
python3 - "$build" "$private" <<'PY'
import hashlib,json,sys
from pathlib import Path
build,private=map(Path,sys.argv[1:])
assert json.loads((build/'module-abi.json').read_text())['kernel_abi_matches']
for info in json.loads((private/'manifest.json').read_text())['images'].values():
    p=private/info['filename'];sha=hashlib.sha256()
    assert p.stat().st_size==info['size']
    with p.open('rb') as f:
        for block in iter(lambda:f.read(4*1024**2),b''):sha.update(block)
    assert sha.hexdigest()==info['sha256']
PY
mkdir -p "$root/opt/shennong/vendor" "$root/lib/modules/$release/extra/vendor_dlkm" \
    "$root/lib/modules/$release/extra/early"
cp --reflink=auto "$private/"*.img "$private/manifest.json" "$root/opt/shennong/vendor/"
make -C "$repo/out/shennong/kernel-source" O="$build" ARCH=arm64 \
    LLVM=/usr/lib/llvm-17/bin/ LOCALVERSION= INSTALL_MOD_PATH="$root" modules_install
cp "$stock_modules/vendor_dlkm/lib/modules/"*.ko "$root/lib/modules/$release/extra/vendor_dlkm/"
cp "$stock_modules/early/lib/modules/"*.ko "$root/lib/modules/$release/extra/early/"
depmod -b "$root" "$release"

# Build the latest config package, so changes made while rootfs downloads
# were in progress are included reproducibly in the final device image.
work=$(mktemp -d "$repo/out/shennong/device-config.XXXXXX")
cp -a "$here/../packages/adaptation-xiaomi-shennong" "$work/source"
(cd "$work/source" && dpkg-buildpackage --no-sign -b)
mkdir -p "$root/var/cache/shennong-adaptation"
cp "$work/"*.deb "$root/var/cache/shennong-adaptation/"
chroot "$root" /bin/sh -c 'dpkg --force-confnew -i /var/cache/shennong-adaptation/*.deb'
rm -r "$root/var/cache/shennong-adaptation"
bash "$here/install-binder-compat.sh" "$root"
bash "$here/install-usb-framework.sh" "$root"
bash "$here/install-cellular-runtime.sh" "$root"
radio_packages=("$repo/out/shennong/telephony-packages/"ofono-binder-plugin_*+shennong2_arm64.deb)
[ "${#radio_packages[@]}" = 1 ] && [ -s "${radio_packages[0]}" ] || {
    echo 'Build the device AIDL plugin with tools/build-ofono-plugin.sh first.' >&2
    exit 1
}
install -m644 "${radio_packages[0]}" "$root/tmp/shennong-ofono.deb"
chroot "$root" dpkg -i /tmp/shennong-ofono.deb
rm "$root/tmp/shennong-ofono.deb"
bridge_packages=("$repo/out/shennong/telephony-packages/"ofono2mm_*+shennong2_all.deb)
[ "${#bridge_packages[@]}" = 1 ] && [ -s "${bridge_packages[0]}" ] || {
    echo 'Build the device modem bridge with tools/build-ofono2mm.sh first.' >&2
    exit 1
}
install -m644 "${bridge_packages[0]}" "$root/tmp/shennong-ofono2mm.deb"
chroot "$root" dpkg -i /tmp/shennong-ofono2mm.deb
rm "$root/tmp/shennong-ofono2mm.deb"

uid=$(awk -F: '$1=="droidian"{print $3}' "$root/etc/passwd")
gid=$(awk -F: '$1=="droidian"{print $4}' "$root/etc/passwd")
# Current Droidian moves its desktop user out of the Android AID range.
# Keep that upstream account mapping rather than forcing the old UID 1000.
[[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $uid -ge 1000 && $uid -lt 65534 ]]
install -d -m700 "$root/home/droidian/.ssh"
install -m600 "$key" "$root/home/droidian/.ssh/authorized_keys"
# Use numeric ownership directly: the builder need not have Droidian's user
# in its own passwd database (some install implementations require that).
python3 - "$root/home/droidian/.ssh" "$uid" "$gid" <<'PY'
import os,sys
from pathlib import Path
directory=Path(sys.argv[1]);uid=int(sys.argv[2]);gid=int(sys.argv[3])
for path in (directory,directory/'authorized_keys'):
    os.chown(path,uid,gid)
PY
for path in "$root/etc/ssh/ssh_host_"*; do [ ! -f "$path" ] || rm "$path"; done
rm -f "$root/etc/systemd/system/sysinit.target.wants/shennong-usb-network.service"
systemctl --root="$root" enable shennong-vendor.service shennong-touch.service \
    shennong-adsp.service shennong-graphics.service shennong-usb-network.service \
    shennong-ssh-hostkeys.service ssh.service phosh.service lxc@android.service
systemctl --root="$root" set-default graphical.target
chroot "$root" usermod -a -G video,render droidian
systemctl --root="$root" mask hybris-usb.service mobian-usb-gadget.service \
    umtp-responder.service usb-tethering.service lxc-net.service lxc.service
# The generic package enables Android mounting under local-fs.target even
# though it runs after that target. Our vendor-image mounts also require the
# root filesystem. Pull this stage from LXC instead, without an ordering cycle.
rm -f "$root/etc/systemd/system/local-fs.target.requires/android-mount.service"
# NetworkManager owns USB addressing, DHCP, DNS and shared-mode NAT.
rm -f "$root/etc/NetworkManager/conf.d/99-shennong-usb0-unmanaged.conf"
chmod 600 "$root/etc/NetworkManager/system-connections/shennong-usb-sharing.nmconnection"
printf '/dev/disk/by-partlabel/linux_root / ext4 defaults,noatime 0 1\n' > "$root/etc/fstab"
mkdir -p "$root/var/lib/systemd/timesync"
# Let systemd use the build time as its normal offline clock floor.
touch "$root/var/lib/systemd/timesync/clock"
chroot "$root" dpkg --audit
echo 'Offline device root prepared; boot and display validation are still required.'
