#!/bin/bash
# Extend the existing native PulseAudio bridge for stable Qualcomm AIDL audio.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo build-audio-passthrough.sh DROIDIAN_BUILD_ROOT}")
[[ $EUID == 0 && $root != / ]]
chroot "$root" pkg-config --exists libgbinder libglibutil gio-2.0
revision=f49813cf9d84bccad4c090e0b554d3219bb5dfec
cache="$repo/out/shennong/audiosystem-passthrough-source"
if [[ ! -d $cache/.git ]]; then
    git init -q "$cache"
    git -C "$cache" remote add origin https://github.com/droidian/audiosystem-passthrough.git
fi
git -C "$cache" cat-file -e "$revision^{commit}" 2>/dev/null ||
    git -C "$cache" fetch --depth 1 origin "$revision"
work=$(mktemp -d "$root/build-shennong-audio-passthrough.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$cache" archive "$revision" | tar -xf - -C "$work"
for change in "$here/../patches/audiosystem-passthrough/"*.patch; do
    patch -d "$work" -p1 < "$change"
done
task_dir="/$(basename "$work")"
chroot "$root" make -C "$task_dir" -j"$(nproc)" KEEP_SYMBOLS=1
python3 - "$repo" "$root" "$work" "$revision" <<'PACKAGE'
import hashlib, json, subprocess, sys, tempfile
from pathlib import Path
repo, root, work = map(Path, sys.argv[1:4])
revision = sys.argv[4]
version = '1.3.0-1+droidian1+git20240519112654.f49813c.next.production+shennong2'
out = repo / 'out/shennong/audio-passthrough-packages'
out.mkdir(parents=True, exist_ok=True)
plugin = work / 'build/audiosystem-passthrough'
with tempfile.TemporaryDirectory(prefix='shennong-audio-passthrough-') as temporary:
    package = Path(temporary)
    directory = package / 'usr/lib/audiosystem-passthrough'
    directory.mkdir(parents=True)
    (directory / plugin.name).write_bytes(plugin.read_bytes())
    (directory / plugin.name).chmod(0o755)
    unit = package / 'usr/lib/systemd/user/audiosystem-passthrough.service'
    unit.parent.mkdir(parents=True)
    unit.write_bytes((work / 'debian/audiosystem-passthrough.user.service').read_bytes())
    doc = package / 'usr/share/doc/audiosystem-passthrough'
    doc.mkdir(parents=True)
    (doc / 'copyright').write_bytes((work / 'LICENSE').read_bytes())
    control_dir = package / 'DEBIAN'
    control_dir.mkdir()
    (control_dir / 'control').write_text(
        'Package: audiosystem-passthrough\nVersion: ' + version + '\n'
        'Architecture: arm64\nSection: sound\nPriority: optional\n'
        'Maintainer: Ning <hwn123123@users.noreply.github.com>\n'
        'Depends: libgbinder (>= 1.1.40), libglibutil, libglib2.0-0t64, libc6\n'
        'Description: Native Qualcomm audio AIDL bridge for the shennong adaptation\n'
        ' Forwards real modem audio session parameters to the PulseAudio HAL backend.\n')
    sums = []
    for path in sorted(package.rglob('*')):
        relative = path.relative_to(package)
        if path.is_file() and not path.is_symlink() and relative.parts[0] != 'DEBIAN':
            sums.append(hashlib.md5(path.read_bytes()).hexdigest() + '  ' + str(relative))
    (control_dir / 'md5sums').write_text('\n'.join(sums) + '\n')
    subprocess.run(['dpkg-deb', '--root-owner-group', '-b', str(package),
                    str(out / f'audiosystem-passthrough_{version}_arm64.deb')], check=True)
(out / 'source.json').write_text(json.dumps({'commit': revision, 'version': version}, indent=2) + '\n')
(out / 'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ./' + path.name + '\n' for path in sorted(out.glob('*.deb'))))
PACKAGE
