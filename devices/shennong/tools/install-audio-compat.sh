#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Offline image preparation only; this never starts or reloads live hardware.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo install-audio-compat.sh DEVICE_ROOT}")
[[ $EUID == 0 && $root != / ]]
grep -qx 'device=shennong' "$root/etc/droidian/shennong-build"
release=6.1.138-android14-11-g0c3d559bcd85-ab14529422
bash "$here/build-audio-compat.sh"
install -D -m644 "$repo/out/shennong/audio-compat-build/shennong_audio_compat.ko" \
    "$root/lib/modules/$release/extra/shennong/shennong_audio_compat.ko"
depmod -b "$root" "$release"
