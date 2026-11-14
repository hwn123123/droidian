#!/usr/bin/env python3
"""Build-time dependency gating; preserve the captured vendor init definitions."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def render_policy(text, service, argv, ready):
    header = re.compile(r'^service[ \t]+' + re.escape(service) + r'[ \t]+' + re.escape(argv) + r'[ \t]*$', re.M)
    if len(header.findall(text)) != 1:
        raise ValueError('Unexpected vendor service definition: ' + service)
    # Class startup must wait for the native host's hardware dependency event.
    text = header.sub(lambda m: m.group(0).rstrip() + '\n    disabled', text, count=1)
    # The original audio service also starts explicitly during early-init.
    text = re.sub(r'^[ \t]+(?:start|restart|enable)\s+' + re.escape(service) + r'[ \t]*\n', '', text, flags=re.M)
    return (text.rstrip() + '\n\n# Linux host driver/DSP dependency handoff.\n'
            + 'on property:' + ready + '=1\n    start ' + service + '\n\n'
            + 'on property:' + ready + '=0\n    stop ' + service + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parent.parent / 'reference/vendor-rpc-services-os309.json')
    args = parser.parse_args()
    policy = json.loads(args.manifest.read_text())
    rendered = {}
    for name, rule in policy.items():
        data = (args.source / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != rule['sha256']:
            raise SystemExit('Captured vendor init input changed: ' + name)
        rendered[name] = render_policy(data.decode(), rule['service'], rule['argv'], rule['ready'])
    args.output.mkdir(parents=True, exist_ok=True)
    for name, text in rendered.items():
        (args.output / name).write_text(text)
    print('Staged native DSP dependency policy for', len(rendered), 'vendor services')


if __name__ == '__main__':
    main()
