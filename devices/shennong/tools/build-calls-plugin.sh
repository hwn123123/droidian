#!/bin/bash
# Build the pinned native Calls application and oFono provider.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
root=$(realpath "${1:?usage: sudo build-calls-plugin.sh DROIDIAN_BUILD_ROOT}")
[[ $EUID == 0 && $root != / ]]
chroot "$root" pkg-config --exists gtk4 libpeas-2 gio-2.0 gio-unix-2.0
revision=d3a2a2242fef42f2e210c564e0220857e575f40c
cache="$repo/out/shennong/calls/source"
if [[ ! -d $cache/.git ]]; then
    git init -q "$cache"
    git -C "$cache" remote add origin https://gitlab.gnome.org/GNOME/calls.git
fi
git -C "$cache" cat-file -e "$revision^{commit}" 2>/dev/null ||
    git -C "$cache" fetch --depth 1 origin "$revision"
fetch_args=(--output "$repo/out/shennong/inputs" --download)
[[ ${SHENNONG_OFFLINE:-0} != 1 ]] || fetch_args+=(--offline)
python3 "$here/fetch-inputs.py" "${fetch_args[@]}"
work=$(mktemp -d "$root/build-shennong-calls.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$cache" archive "$revision" | tar -xf - -C "$work"
ui_revision=3a2044f8e7c45387954ed35d22c6b6309e6751d6
ui_cache="$repo/out/shennong/calls/libcall-ui-source"
if [[ ! -d $ui_cache/.git ]]; then
    git init -q "$ui_cache"
    git -C "$ui_cache" remote add origin https://gitlab.gnome.org/World/Phosh/libcall-ui.git
fi
git -C "$ui_cache" cat-file -e "$ui_revision^{commit}" 2>/dev/null ||
    git -C "$ui_cache" fetch --depth 1 origin "$ui_revision"
mkdir -p "$work/subprojects/libcall-ui"
git -C "$ui_cache" archive "$ui_revision" | tar -xf - -C "$work/subprojects/libcall-ui"

for change in "$here/../patches/gnome-calls/"*.patch; do
    patch -d "$work" -p1 < "$change"
done
task_dir="/$(basename "$work")"
chroot "$root" bash -s -- "$task_dir" <<'BUILD'
set -euo pipefail
cd "$1"
meson setup _build --prefix=/usr --libdir=lib/aarch64-linux-gnu \
    --buildtype=release --wrap-mode=nodownload -Dtests=false -Dgtk_doc=false -Dmanpages=false
meson compile -C _build
msgfmt --check -o calls-zh_CN.mo po/zh_CN.po
BUILD
python3 - "$repo" "$root" "$work" "$revision" "$ui_revision" <<'PACKAGE'
import hashlib, json, subprocess, sys, tempfile
from pathlib import Path
repo, root, work = map(Path, sys.argv[1:4])
revision, ui_revision = sys.argv[4:6]
inputs = repo / 'out/shennong/inputs'
base = json.loads((inputs / 'inputs.lock.json').read_text())['packages']['gnome-calls']
if base['version'] != '51.1-1' or base['architecture'] != 'arm64':
    raise SystemExit('Calls archive does not match the pinned provider API')
archive = inputs / 'packages' / Path(base['filename']).name
if hashlib.sha256(archive.read_bytes()).hexdigest() != base['sha256']:
    raise SystemExit('Calls archive checksum mismatch')
out = repo / 'out/shennong/calls-packages'
out.mkdir(parents=True, exist_ok=True)
version = base['version'] + '+shennong3'
with tempfile.TemporaryDirectory(prefix='shennong-calls-') as temporary:
    package = Path(temporary)
    subprocess.run(['dpkg-deb', '-R', str(archive), str(package)], check=True)
    def symbols(path):
        lines = subprocess.check_output(['readelf', '--dyn-syms', '--wide', str(path)], text=True).splitlines()
        return [line.split() for line in lines if len(line.split()) >= 8 and line.split()[0].rstrip(':').isdigit()]
    exports = {fields[7] for fields in symbols(package / 'usr/bin/gnome-calls') if fields[6] != 'UND'}
    required = {fields[7] for fields in symbols(work / '_build/plugins/provider/ofono/libofono.so') if fields[6] == 'UND' and fields[7].startswith('calls_')}
    if required - exports:
        raise SystemExit('Provider requires missing Calls symbols: ' + repr(sorted(required - exports)))
    providers = list(package.glob('usr/lib/**/calls/plugins/provider/ofono/libofono.so'))
    if len(providers) != 1:
        raise SystemExit('Unexpected Calls provider layout')
    providers[0].write_bytes((work / '_build/plugins/provider/ofono/libofono.so').read_bytes())
    (package / 'usr/bin/gnome-calls').write_bytes((work / '_build/src/gnome-calls').read_bytes())
    (package / 'usr/share/locale/zh_CN/LC_MESSAGES/calls.mo').write_bytes((work / 'calls-zh_CN.mo').read_bytes())
    control = package / 'DEBIAN/control'
    control.write_text(control.read_text().replace('Version: ' + base['version'], 'Version: ' + version))
    sums = []
    for path in sorted(package.rglob('*')):
        relative = path.relative_to(package)
        if path.is_file() and not path.is_symlink() and relative.parts[0] != 'DEBIAN':
            sums.append(hashlib.md5(path.read_bytes()).hexdigest() + '  ' + str(relative))
    (package / 'DEBIAN/md5sums').write_text('\n'.join(sums) + '\n')
    subprocess.run(['dpkg-deb', '--root-owner-group', '-b', str(package), str(out / f'gnome-calls_{version}_arm64.deb')], check=True)
(out / 'source.json').write_text(json.dumps({'commit': revision, 'libcall_ui_commit': ui_revision, 'base_package': base, 'version': version}, indent=2) + '\n')
(out / 'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ./' + path.name + '\n' for path in sorted(out.glob('*.deb'))))
PACKAGE
