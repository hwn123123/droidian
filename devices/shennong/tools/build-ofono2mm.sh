#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
revision=feedd6c2f518456c6b87c701b99ffaf50974f757
cache="$repo/out/shennong/telephony/ofono2mm-source"
if [ ! -d "$cache/.git" ]; then
    git init -q "$cache"
    git -C "$cache" remote add origin https://github.com/droidian/oFono2MM.git
fi
git -C "$cache" cat-file -e "$revision^{commit}" 2>/dev/null || \
    git -C "$cache" fetch --depth 1 origin "$revision"
fetch_args=(--output "$repo/out/shennong/inputs" --download)
[ "${SHENNONG_OFFLINE:-0}" != 1 ] || fetch_args+=(--offline)
python3 "$here/fetch-inputs.py" "${fetch_args[@]}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$cache" archive "$revision" | tar -x -C "$work"
for patch in "$here/../patches/ofono2mm/"*.patch; do
    patch -d "$work" -p1 < "$patch"
done
python3 -m compileall -q "$work/ofono2mm"
python3 -m py_compile "$work/main.py"
python3 - "$repo" "$work" "$revision" <<'PY'
import hashlib, json, subprocess, sys, tempfile
from pathlib import Path
repo, work = map(Path, sys.argv[1:3])
revision = sys.argv[3]
inputs = repo / 'out/shennong/inputs'
base = json.loads((inputs / 'inputs.lock.json').read_text())['packages']['ofono2mm']
if 'feedd6c' not in base['version']:
    raise SystemExit('The archive bridge no longer matches the pinned source')
archive = inputs / 'packages' / Path(base['filename']).name
if hashlib.sha256(archive.read_bytes()).hexdigest() != base['sha256']:
    raise SystemExit('Upstream bridge package checksum mismatch')
version = base['version'] + '+shennong7'
out = repo / 'out/shennong/telephony-packages'
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='shennong-ofono2mm-') as temporary:
    package = Path(temporary)
    subprocess.run(['dpkg-deb', '-R', str(archive), str(package)], check=True)
    for source in (work / 'ofono2mm').glob('*.py'):
        (package / 'usr/lib/ofono2mm/ofono2mm' / source.name).write_bytes(source.read_bytes())
    (package / 'usr/lib/ofono2mm/main.py').write_bytes((work / 'main.py').read_bytes())
    control = package / 'DEBIAN/control'
    control.write_text(control.read_text().replace('Version: ' + base['version'],
                                               'Version: ' + version))
    sums = []
    for path in sorted(package.rglob('*')):
        relative = path.relative_to(package)
        if path.is_file() and not path.is_symlink() and relative.parts[0] != 'DEBIAN':
            sums.append(hashlib.md5(path.read_bytes()).hexdigest() + '  ' + str(relative))
    (package / 'DEBIAN/md5sums').write_text('\n'.join(sums) + '\n')
    subprocess.run(['dpkg-deb', '--root-owner-group', '-b', str(package),
        str(out / ('ofono2mm_' + version + '_all.deb'))], check=True)
PY
