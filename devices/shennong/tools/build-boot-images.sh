#!/usr/bin/env bash
# Offline packaging: preserve the working REC dispatcher and B vendor ramdisk.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../../.." && pwd -P)
[[ $# == 3 ]] || { echo "usage: $0 CAPTURED_B_DIRECTORY MAGISKBOOT OUTPUT_DIRECTORY" >&2; exit 2; }
base=$(realpath "$1")
magiskboot=$(realpath "$2")
out=$(realpath -m "$3")
build="$repo/out/shennong/kernel-display-build"
[[ ! -e $out ]] || { echo 'Output directory already exists' >&2; exit 1; }
python3 - "$base" "$build" <<'PY'
import hashlib,json,sys
from pathlib import Path
base,build=map(Path,sys.argv[1:])
manifest=json.loads((base/'manifest.json').read_text())
for name,info in manifest.items():
    p=base/(name+'.img')
    assert p.stat().st_size==info['size']
    assert hashlib.sha256(p.read_bytes()).hexdigest()==info['sha256']
abi=json.loads((build/'module-abi.json').read_text())
assert abi['kernel_abi_matches'] and abi['checked_kernel_imports']>30000
PY
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$out" "$work/init" "$work/boot"
gcc -static -O2 -std=c11 -Wall -Wextra -Werror -ffunction-sections \
    -fdata-sections -Wl,--gc-sections -o "$work/droidian-init" "$here/../initramfs/boot-shim.c"
file "$work/droidian-init" | grep -F 'ARM aarch64'
(
    cd "$work/init"
    "$magiskboot" unpack "$base/init_boot_b.img"
    "$magiskboot" cpio ramdisk.cpio 'extract android-first-stage-init android-first-stage-init'
    [[ $(sha256sum android-first-stage-init | cut -d ' ' -f 1) == 5f2b3f295c45e60668dc596169389a38a198e4693e107e77ab5e705d488f2ac6 ]]
    "$magiskboot" cpio ramdisk.cpio "add 0755 init $work/droidian-init" 'rm early-splash'
    "$magiskboot" repack "$base/init_boot_b.img" "$out/init_boot_b.img"
)
(
    cd "$work/boot"
    "$magiskboot" unpack -h "$base/boot_b.img"
    [[ $(sha256sum kernel | cut -d ' ' -f 1) == 97b2c53022e8c0bd0b279c4c592a196126a6eb0a93647c2957b39dcd5f2dc1c9 ]]
    cp "$build/arch/arm64/boot/Image" kernel
    # Halium runs Android services in a privileged container under Linux.
    # Disable the Android host SELinux policy only on this B boot image.
    python3 - <<'PY'
from pathlib import Path
p=Path('header');lines=p.read_text().splitlines();result=[]
for line in lines:
    if line.startswith('cmdline='):
        line=line+' selinux=0'
    result.append(line)
p.write_text('\n'.join(result)+'\n')
PY
    "$magiskboot" repack "$base/boot_b.img" "$out/boot_b.img"
)
for part in boot_b init_boot_b; do
    case $part in boot_b) size=100663296 ;; init_boot_b) size=8388608 ;; esac
    [[ $(stat -c %s "$out/$part.img") -le $size ]]
    truncate -s "$size" "$out/$part.img"
done
cp "$build/module-abi.json" "$out/module-abi.json"
(cd "$out" && sha256sum boot_b.img init_boot_b.img > SHA256SUMS)
echo "Boot payload built in $out; no partitions were written."
