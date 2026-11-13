#!/usr/bin/env python3
"""Stage verified appearance inputs and install built Phosh packages offline."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request

device = Path(__file__).resolve().parents[1]
repo = device.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--offline', action='store_true')
args = parser.parse_args()
root = args.root.resolve()
if root == Path('/') or not (root / 'etc/droidian/shennong-build').is_file():
    raise SystemExit('Select the offline device root, not the host root')
lock = json.loads((device / 'ui-packages.json').read_text())
cache = repo / 'out/shennong/ui/packages'
cache.mkdir(parents=True, exist_ok=True)
archives = []
for package in lock['packages']:
    path = cache / package['file']
    if not path.is_file():
        if args.offline:
            raise SystemExit(f'Missing appearance package: {path}')
        url = lock['base'] + package['path'] + urllib.parse.quote(package['file'], safe='+')
        with urllib.request.urlopen(url, timeout=90) as response:
            path.write_bytes(response.read())
    if hashlib.sha256(path.read_bytes()).hexdigest() != package['sha256']:
        raise SystemExit(f'Appearance package checksum mismatch: {path}')
    archives.append(path)

version = '0.55.0+git20260824233009.bee1861.next.phosh.0.55+shennong3'
output = repo / 'out/shennong/ui-packages'
for name, architecture in [('phosh', 'arm64'), ('phosh-common', 'all'),
                           ('phosh-plugins', 'arm64'), ('phosh-mobile-tweaks', 'all')]:
    path = output / f'{name}_{version}_{architecture}.deb'
    if not path.is_file():
        raise SystemExit('Build the native phone home with tools/build-phosh.sh first')
    archives.append(path)

staged = root / 'tmp/shennong-ui-packages'
staged.mkdir(parents=True, exist_ok=True)
try:
    import shutil
    for archive in archives:
        shutil.copyfile(archive, staged / archive.name)
    subprocess.run(['chroot', str(root), 'dpkg', '-i',
                    *['/tmp/shennong-ui-packages/' + p.name for p in archives]], check=True)
finally:
    shutil.rmtree(staged)
