#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Rebuild the pinned Droidian plugin with the isolated AIDL adaptation patch.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo build-ofono-plugin.sh DROIDIAN_BUILD_ROOT}")
[ "$EUID" = 0 ] && [ "$root" != / ]
chroot "$root" pkg-config --exists ofono libgbinder-radio libgbinder libglibutil glib-2.0 gio-2.0
revision=9b9e8bd2ffc8a6ba482d6daf7171fd84ba82c3b8
cache="$repo/out/shennong/telephony/ofono-binder-plugin-source"
if [ ! -d "$cache/.git" ]; then
    git init -q "$cache"
    git -C "$cache" remote add origin https://github.com/droidian/ofono-binder-plugin.git
fi
git -C "$cache" cat-file -e "$revision^{commit}" 2>/dev/null || \
    git -C "$cache" fetch --depth 1 origin "$revision"
python3 "$here/fetch-inputs.py" --output "$repo/out/shennong/inputs" --download
work=$(mktemp -d "$root/build-shennong-radio.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$cache" archive "$revision" | tar -x -C "$work"
for patch in "$here/../patches/ofono-binder-plugin/"*.patch; do
    patch -d "$work" -p1 < "$patch"
done
cp "$here/../tests/test_signal_calibration.c" "$work/"
chroot "$root" cc -std=c11 -Wall -Wextra -Werror \
    -I"/$(basename "$work")/src" "/$(basename "$work")/test_signal_calibration.c" \
    -o "/$(basename "$work")/test_signal_calibration"
chroot "$root" "/$(basename "$work")/test_signal_calibration"
chroot "$root" make -C "/$(basename "$work")" -j"$(nproc)" release
chroot "$root" make -C "/$(basename "$work")" -j"$(nproc)" test
python3 - "$repo" "$work" "$revision" <<'PY'
import hashlib, json, subprocess, sys, tempfile
from pathlib import Path
repo, work = map(Path, sys.argv[1:3])
revision = sys.argv[3]
inputs = repo / 'out/shennong/inputs'
base = json.loads((inputs / 'inputs.lock.json').read_text())['packages']['ofono-binder-plugin']
if '9b9e8bd' not in base['version']:
    raise SystemExit('The archive plugin no longer matches the pinned AIDL source')
archive = inputs / 'packages' / Path(base['filename']).name
if hashlib.sha256(archive.read_bytes()).hexdigest() != base['sha256']:
    raise SystemExit('Upstream plugin package checksum mismatch')
version = base['version'] + '+shennong3'
out = repo / 'out/shennong/telephony-packages'
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='shennong-radio-') as temporary:
    package = Path(temporary)
    subprocess.run(['dpkg-deb', '-R', str(archive), str(package)], check=True)
    plugins = list(package.glob('usr/lib/**/binderplugin.so'))
    if len(plugins) != 1:
        raise SystemExit('Unexpected upstream plugin layout')
    plugins[0].write_bytes((work / 'build/release/binderplugin.so').read_bytes())
    control = package / 'DEBIAN/control'
    text = control.read_text()
    control.write_text(text.replace('Version: ' + base['version'], 'Version: ' + version))
    sums = []
    for path in sorted(package.rglob('*')):
        relative = path.relative_to(package)
        if path.is_file() and not path.is_symlink() and relative.parts[0] != 'DEBIAN':
            sums.append(hashlib.md5(path.read_bytes()).hexdigest() + '  ' + str(relative))
    (package / 'DEBIAN/md5sums').write_text('\n'.join(sums) + '\n')
    subprocess.run(['dpkg-deb', '--root-owner-group', '-b', str(package),
                    str(out / ('ofono-binder-plugin_' + version + '_arm64.deb'))], check=True)
(out / 'source.json').write_text(json.dumps({'commit': revision, 'base_package': base,
    'version': version}, indent=2) + '\n')
PY
