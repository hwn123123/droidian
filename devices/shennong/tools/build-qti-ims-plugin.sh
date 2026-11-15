#!/bin/bash
# Build the native Qualcomm IMS extension against the pinned Droidian ABI.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo build-qti-ims-plugin.sh DROIDIAN_BUILD_ROOT}")
[[ $EUID == 0 && $root != / ]]
chroot "$root" pkg-config --exists ofono libgbinder-radio libgbinder libglibutil gobject-2.0
revision=71b9d419c3628b10208b04d0e5117f33815a1ac6
binder_revision=9b9e8bd2ffc8a6ba482d6daf7171fd84ba82c3b8
cache="$repo/out/shennong/telephony/ofono-qti-source"
binder_cache="$repo/out/shennong/telephony/ofono-binder-plugin-source"
if [[ ! -d $cache/.git ]]; then
    git init -q "$cache"
    git -C "$cache" remote add origin https://gitlab.com/ubports/development/core/hybris-support/ofono-binder-plugin-ext-qti.git
fi
git -C "$cache" cat-file -e "$revision^{commit}" 2>/dev/null ||
    git -C "$cache" fetch --depth 1 origin "$revision"
git -C "$binder_cache" cat-file -e "$binder_revision^{commit}"
work=$(mktemp -d "$root/build-shennong-qti-ims.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$cache" archive "$revision" | tar -xf - -C "$work"
mkdir -p "$work/binder-headers"
git -C "$binder_cache" archive "$binder_revision" lib/include |
    tar -xf - -C "$work/binder-headers" --strip-components=2
if [[ -d $here/../patches/ofono-qti ]]; then
    for change in "$here/../patches/ofono-qti/"*.patch; do
        [[ -f $change ]] && patch -d "$work" -p1 < "$change"
    done
fi
task_dir="/$(basename "$work")"
chroot "$root" make -C "$task_dir" -j"$(nproc)" release \
    PKGS='ofono libgbinder-radio libgbinder libglibutil gobject-2.0 glib-2.0' \
    LDPKGS='libgbinder-radio libgbinder libglibutil gobject-2.0 glib-2.0' \
    CFLAGS="-I$task_dir/binder-headers" \
    LDFLAGS='-Wl,-z,relro,-z,now -l:libofonobinderpluginext.so.1'
python3 - "$repo" "$root" "$work" "$revision" "$binder_revision" <<'PACKAGE'
import hashlib, json, subprocess, sys, tempfile
from pathlib import Path
repo, root, work = map(Path, sys.argv[1:4])
revision, binder_revision = sys.argv[4:6]
version = '1.0+git20261112.71b9d41+shennong2'
out = repo / 'out/shennong/qti-ims-packages'
out.mkdir(parents=True, exist_ok=True)
plugin = work / 'build/release/qtibinderpluginext.so'
with tempfile.TemporaryDirectory(prefix='shennong-qti-ims-') as temporary:
    package = Path(temporary)
    directory = package / 'usr/lib/aarch64-linux-gnu/ofono/plugins'
    directory.mkdir(parents=True)
    (directory / plugin.name).write_bytes(plugin.read_bytes())
    (directory / plugin.name).chmod(0o755)
    config = package / 'etc/ofono/binder.d/95-shennong-qti-ims.conf'
    config.parent.mkdir(parents=True)
    config.write_text('[Settings]\n# Native extension for the stock Qualcomm IMS AIDL services.\nextPlugin = qti\n')
    doc = package / 'usr/share/doc/ofono-binder-plugin-ext-qti'
    doc.mkdir(parents=True)
    (doc / 'copyright').write_bytes((work / 'LICENSE').read_bytes())
    control_dir = package / 'DEBIAN'
    control_dir.mkdir()
    (control_dir / 'conffiles').write_text('/etc/ofono/binder.d/95-shennong-qti-ims.conf\n')
    (control_dir / 'control').write_text(
        'Package: ofono-binder-plugin-ext-qti\nVersion: ' + version + '\n'
        'Architecture: arm64\nSection: comm\nPriority: optional\n'
        'Maintainer: Ning <hwn123123@users.noreply.github.com>\n'
        'Depends: ofono, ofono-binder-plugin, libofonobinderpluginext, libgbinder, libgbinder-radio, libglibutil, libglib2.0-0t64, libc6\n'
        'Description: Native Qualcomm IMS AIDL extension for the shennong adaptation\n'
        ' Integrates vendor IMS calls with the existing oFono Binder backend.\n')
    sums = []
    for path in sorted(package.rglob('*')):
        relative = path.relative_to(package)
        if path.is_file() and not path.is_symlink() and relative.parts[0] != 'DEBIAN':
            sums.append(hashlib.md5(path.read_bytes()).hexdigest() + '  ' + str(relative))
    (control_dir / 'md5sums').write_text('\n'.join(sums) + '\n')
    subprocess.run(['dpkg-deb', '--root-owner-group', '-b', str(package),
                    str(out / f'ofono-binder-plugin-ext-qti_{version}_arm64.deb')], check=True)
(out / 'source.json').write_text(json.dumps({'commit': revision, 'binder_abi_commit': binder_revision, 'version': version}, indent=2) + '\n')
(out / 'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ./' + path.name + '\n' for path in sorted(out.glob('*.deb'))))
PACKAGE
