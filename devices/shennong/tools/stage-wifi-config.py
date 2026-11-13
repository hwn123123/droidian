#!/usr/bin/env python3
"""Derive the host WLAN configuration from the unmodified private vendor input."""
import argparse
import hashlib
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
source = args.source.resolve()
output = args.output.absolute()
if source == output.resolve():
    raise SystemExit('The private stock configuration must remain unchanged')
data = source.read_bytes()
expected = 'c675c32b4f0e6cb6379c801297bc8cffc835ce07c9ac3155645844e4d4b3b8d5'
if hashlib.sha256(data).hexdigest() != expected:
    raise SystemExit('Unknown stock WLAN configuration; review the vendor input first')

# This stock module is built with IPA_OPT_WIFI_DP. In that implementation,
# zero selects the enabled 0x27d profile. 0xeeeeeeee selects the native host
# data path. Keep normal driver idle shutdown and station power saving.
data, replacements = re.subn(rb'(?m)^gIPAConfig=0\r?$',
                              b'gIPAConfig=0xEEEEEEEE', data)
if replacements != 2:
    raise SystemExit('Stock IPA entries changed; refusing an incomplete adaptation')
output.parent.mkdir(parents=True, exist_ok=True)
temporary = output.with_suffix(output.suffix + '.new')
temporary.write_bytes(data)
temporary.chmod(0o644)
temporary.replace(output)
print('Generated native-host WLAN configuration; stock vendor input preserved')
