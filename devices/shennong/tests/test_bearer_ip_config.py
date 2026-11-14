#!/usr/bin/env python3
"""Validate the bridge contract consumed by NetworkManager (patched source argv1)."""
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest

from dbus_next import Variant

sys.path.insert(0, str(Path(sys.argv.pop(1)).resolve()))
from ofono2mm.mm_bearer import MMBearerInterface


class BearerIPTest(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.modem = SimpleNamespace(props={'Ports': Variant('a(su)', [])},
            emit_properties_changed=lambda event: self.events.append(event))
        self.context = SimpleNamespace(on_property_changed=lambda callback: None)
        client = {'ofono_modem': {'/ril_0': {}},
                  'ofono_context': {'/ril_0/context1': {
                      'org.ofono.ConnectionContext': self.context}}}
        self.bearer = MMBearerInterface(0, None, client, '/ril_0', None, {}, {}, {}, self.modem)

    def config(self):
        return {key: val.value for key, val in self.bearer.props['Ip6Config'].value.items()}

    def settings(self):
        return Variant('a{sv}', {'Interface': Variant('s', 'rmnet_data2'),
            'Address': Variant('s', '2001:db8::2'), 'PrefixLength': Variant('y', 64),
            'Gateway': Variant('s', '2001:db8::1'),
            'DomainNameServers': Variant('as', ['2001:db8::53'])})

    def test_ipv4_only_context_has_no_ipv6_dhcp(self):
        self.bearer.set_context('/ril_0/context1', {'Settings': Variant('a{sv}', {
            'Method': Variant('s', 'static'), 'Address': Variant('s', '192.0.2.2')})})
        self.assertEqual(self.config(), {'method': 0})

    def test_existing_ipv6_context_is_available_at_publication(self):
        self.bearer.set_context('/ril_0/context1', {'IPv6.Settings': self.settings()})
        self.assertEqual(self.config(), {'method': 2, 'address': '2001:db8::2',
            'prefix': 64, 'gateway': '2001:db8::1', 'dns1': '2001:db8::53'})
        self.assertEqual(self.bearer.props['Interface'].value, 'rmnet_data2')
        self.assertEqual(self.modem.props['Ports'].value, [['rmnet_data2', 2]])

    def test_ipv6_loss_removes_old_routes_and_dns(self):
        self.bearer.ofono_context_changed('IPv6.Settings', self.settings())
        self.bearer.ofono_context_changed('IPv6.Settings', Variant('a{sv}', {}))
        self.assertEqual(self.config(), {'method': 0})

    def test_malformed_ipv6_does_not_escape_dbus_callback(self):
        for field, value in [('Address', Variant('s', 'not-an-ip')),
                             ('PrefixLength', Variant('y', 129)),
                             ('Gateway', Variant('s', '192.0.2.1'))]:
            settings = self.settings()
            settings.value[field] = value
            self.bearer.ofono_context_changed('IPv6.Settings', settings)
            self.assertEqual(self.config(), {'method': 0})


if __name__ == '__main__':
    unittest.main()
