#!/usr/bin/env bash
# Build the exact stock kernel source with the Halium configuration fragment.
# This script produces build artifacts only. It never creates or flashes boot.img.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../../.." && pwd -P)
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || {
    echo 'Use the arm64 Linux builder.' >&2; exit 1;
}
[[ $# == 2 ]] || { echo "usage: $0 KERNEL_SOURCE_ARCHIVE STOCK_CONFIG.gz" >&2; exit 2; }
archive=$(realpath "$1")
config=$(realpath "$2")
expected_archive_sha=04d8bea99e51c9204dc4fd9df29bcd69e900ba2ad80ad062aeb4899feb8aa985
[[ $(sha256sum "$archive" | cut -d ' ' -f 1) == "$expected_archive_sha" ]] || {
    echo 'Kernel source archive does not match the pinned stock source.' >&2; exit 1;
}
profile=${SHENNONG_KERNEL_PROFILE:-display}
[[ $profile == display || $profile == halium ]]
out="$repo/out/shennong/kernel-$profile-build"
source_dir="$repo/out/shennong/kernel-source"
commit=0c3d559bcd85c64dae9c9c9687abbe5347fff3ad
release=6.1.138-android14-11-g0c3d559bcd85-ab14529422
llvm_prefix=${SHENNONG_LLVM_PREFIX:-/usr/lib/llvm-17/bin/}
[[ -x ${llvm_prefix}clang && -x ${llvm_prefix}ld.lld ]]
mkdir -p "$out"
if [[ ! -d $source_dir ]]; then
    mkdir -p "$source_dir"
    tar -xzf "$archive" -C "$source_dir"
    printf '%s\n' "$commit" > "$source_dir/.shennong-source-commit"
fi
[[ $(cat "$source_dir/.shennong-source-commit") == "$commit" ]]
[[ $(sed -n 's/^SUBLEVEL = //p' "$source_dir/Makefile") == 138 ]]
# Host libbpf needs a const-correct pointer with the newer build-host libc.
# This changes the build utility only, not the target kernel or a driver.
host_patch="$here/../compat/libbpf-host-const.patch"
patch_sha=$(sha256sum "$host_patch" | cut -d ' ' -f 1)
if [[ -f $source_dir/.shennong-host-compat ]]; then
    [[ $(cat "$source_dir/.shennong-host-compat") == "$patch_sha" ]]
else
    patch --batch -d "$source_dir" -p1 -i "$host_patch"
    printf '%s\n' "$patch_sha" > "$source_dir/.shennong-host-compat"
fi
gzip -dc "$config" > "$out/.config"
"$source_dir/scripts/kconfig/merge_config.sh" -m -O "$out" \
    "$out/.config" "$here/../kernel/$profile.config"
"$source_dir/scripts/config" --file "$out/.config" \
    --enable LOCALVERSION_AUTO --disable TRIM_UNUSED_KSYMS \
    --set-str UNUSED_KSYMS_WHITELIST '' --set-str SYSTEM_TRUSTED_KEYS '' \
    --set-str LOCALVERSION "${release#6.1.138}"
make -C "$source_dir" O="$out" ARCH=arm64 LLVM="$llvm_prefix" LOCALVERSION= olddefconfig
python3 "$here/check-prerequisites.py" \
    --properties "$repo/out/shennong/evidence/android-api.txt" --config "$out/.config" \
    --profile "$profile" \
    --json "$out/prerequisites.json"
make -C "$source_dir" O="$out" ARCH=arm64 LLVM="$llvm_prefix" LOCALVERSION= \
    -j"$(nproc)" Image modules
[[ $(cat "$out/include/config/kernel.release") == "$release" ]]
sha256sum "$out/arch/arm64/boot/Image" > "$out/Image.sha256"
echo 'Kernel built. Check Module.symvers against the captured vendor modules before packaging.'
