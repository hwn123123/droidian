#!/bin/sh
set -eu

dpkg -i /var/cache/shennong-adaptation/*.deb
apt-get check
sed -i 's/^# *\(zh_CN.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen zh_CN.UTF-8
update-locale LANG=zh_CN.UTF-8
ln -sfn /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
printf '%s\n' Asia/Shanghai > /etc/timezone
mkdir -p /etc/droidian
printf '%s\n' 'device=shennong' 'vendor_api=34' 'display_backend=hwcomposer' \
    'root_partition=linux_root' > /etc/droidian/shennong-build

# Keep rootfs creation separate from all kernel flashing and partition actions.
# The packages contain configuration only; no boot-image postinst is installed.
rm -r /var/cache/shennong-adaptation
rm -f /etc/apt/apt.conf.d/99-shennong-build-proxy
apt-get clean
