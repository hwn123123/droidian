#!/system/bin/sh
# Apply a checked payload from the existing authenticated NWRT REC.
set -eu
export PATH=/system/bin:/system/xbin:/nwrt/bin
[ $# -eq 1 ] || { echo 'usage: install-from-recovery.sh PAYLOAD_DIRECTORY' >&2; exit 2; }
cd "$1"
[ "$(getprop ro.product.device)" = shennong ]
[ "$(getprop ro.boot.slot_suffix)" = _a ]
[ -x /nwrt/bin/nwrt-root ]
[ "$(blockdev --getsize64 /dev/block/by-name/linux_root)" = 214748364800 ]
[ "$(readlink -f /dev/block/by-name/linux_root)" = /dev/block/sda34 ]
# REC's sgdisk cannot query disk geometry under this SELinux domain. The
# host validates both GPT CRCs and boundaries before creating these hashes.
# Compare those exact sectors here; never repair or rewrite the GPT.
verify_layout() {
    [ "$(blockdev --getsize64 /dev/block/sda)" = 526854914048 ]
    [ "$(blockdev --getss /dev/block/sda)" = 4096 ]
    dd if=/dev/block/sda bs=4096 count=6 2>/dev/null > gpt-primary.current
    dd if=/dev/block/sda bs=4096 skip=128626682 count=6 2>/dev/null > gpt-backup.current
    sha256sum -c GPT-SHA256SUMS
}
verify_layout
sha256sum -c PAYLOAD-SHA256SUMS
sha256sum -c PRESERVED-SHA256SUMS
for part in boot_b init_boot_b; do
    case $part in boot_b) bytes=100663296 ;; init_boot_b) bytes=8388608 ;; esac
    [ "$(blockdev --getsize64 /dev/block/by-name/$part)" = "$bytes" ]
    [ "$(stat -c %s "$part.img")" = "$bytes" ]
done
[ "$(od -An -tx1 -N4 linux_root-droidian.simg | tr -d ' \n')" = 3aff26ed ]
for part in qupfw_a qupfw_b; do
    [ "$(blockdev --getsize64 /dev/block/by-name/$part)" = 131072 ]
done
cmp /dev/block/by-name/qupfw_a /dev/block/by-name/qupfw_b
root_device=$(readlink -f /dev/block/by-name/linux_root)
if grep -qE "^($root_device|/dev/block/by-name/linux_root) " /proc/mounts; then
    echo 'linux_root is mounted; refusing installation' >&2
    exit 1
fi
/nwrt/bin/simg2img linux_root-droidian.simg /dev/block/by-name/linux_root
sync
mkdir -p /mnt/droidian-check
mount -t ext4 /dev/block/by-name/linux_root /mnt/droidian-check
trap 'umount /mnt/droidian-check 2>/dev/null || true' EXIT
grep -qx 'device=shennong' /mnt/droidian-check/etc/droidian/shennong-build
grep -qx 'display_backend=hwcomposer' /mnt/droidian-check/etc/droidian/shennong-build
# REC's SELinux policy intentionally disallows executing arbitrary Linux
# binaries. access(X_OK) therefore fails even for a valid mode-0755 file.
# Verify the file, its POSIX execute bits and ELF magic without executing it.
for program in /mnt/droidian-check/usr/lib/systemd/systemd /mnt/droidian-check/usr/sbin/sshd; do
    [ -f "$program" ]
    mode=$(stat -c %a "$program")
    [ "$((0$mode & 0111))" -ne 0 ]
    [ "$(od -An -tx1 -N4 "$program" | tr -d ' \n')" = 7f454c46 ]
done
[ -s /mnt/droidian-check/home/droidian/.ssh/authorized_keys ]
[ -s /mnt/droidian-check/opt/shennong/vendor/vendor.img ]
umount /mnt/droidian-check
trap - EXIT
for part in boot_b init_boot_b; do
    expected=$(sha256sum "$part.img" | cut -d ' ' -f 1)
    dd "if=$part.img" "of=/dev/block/by-name/$part" bs=1048576
    sync
    [ "$(sha256sum /dev/block/by-name/$part | cut -d ' ' -f 1)" = "$expected" ]
done
sha256sum -c PRESERVED-SHA256SUMS
verify_layout
if [ -d /metadata/linux-multiboot ]; then
    printf '%s\n' shennong-linux-b-ready-v1 > /metadata/linux-multiboot/b-slot-ready
    sync
fi
echo 'Droidian rootfs and B boot images installed and checked. No automatic slot switch or reboot.'
