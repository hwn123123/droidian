#!/usr/bin/env python3
"""Select the device's DRM descriptor compatibility inside the stock service."""
import argparse
import hashlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
name = 'vendor.qti.hardware.display.composer-service.rc'
data = (args.source / name).read_bytes()
if hashlib.sha256(data).hexdigest() != '364d50fd56536e6a1eccf20e5d06cdda689dc89b661afb2c0c86bbb41e931a5d':
    raise SystemExit('Captured Composer service changed')
text = data.decode()
header = ('service vendor.qti.hardware.display.composer '
          '/vendor/bin/hw/vendor.qti.hardware.display.composer-service\n')
if not text.startswith(header) or 'LD_PRELOAD' in text:
    raise SystemExit('Unexpected Composer service layout')
text = text.replace(header, header +
    '    setenv LD_PRELOAD /vendor/lib64/libshennong-drm-compat.so\n'
    '    setenv SHENNONG_DRM_SHARED_MASTER 1\n', 1)
args.output.mkdir(parents=True, exist_ok=True)
(args.output / name).write_text(text)
print('Staged the stock Composer service with scoped DRM descriptor adaptation')
