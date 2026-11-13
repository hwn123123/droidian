#!/usr/bin/env python3
"""Run with dbus-run-session and the patched ofono2mm source directory."""
import asyncio
from pathlib import Path
import runpy
import sys
import unittest
from unittest.mock import patch

from dbus_next import Message, MessageType
from dbus_next.aio import MessageBus
from dbus_next.constants import PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property

source = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(source))
with patch('asyncio.run', lambda coroutine: coroutine.close()):
    MMMessageBus = runpy.run_path(str(source / 'main.py'))['MMMessageBus']

ROOT = '/org/freedesktop/ModemManager1'
MODEM = ROOT + '/Modem/0'
OBJECT_MANAGER = 'org.freedesktop.DBus.ObjectManager'


class Modem(ServiceInterface):
    def __init__(self):
        super().__init__('org.freedesktop.ModemManager1.Modem')

    @dbus_property(access=PropertyAccess.READ)
    def State(self) -> 'i':
        return 3


class Ussd(ServiceInterface):
    def __init__(self):
        super().__init__('org.freedesktop.ModemManager1.Modem.Modem3gpp.Ussd')

    @dbus_property(access=PropertyAccess.READ)
    async def NetworkRequest(self) -> 's':
        return 'ready'


class PublicationTest(unittest.IsolatedAsyncioTestCase):
    async def test_complete_object_is_published_once_with_async_properties(self):
        service = await MMMessageBus().connect()
        client = await MessageBus().connect()
        try:
            service.export(ROOT, ServiceInterface('org.freedesktop.ModemManager1'))
            added = []
            received = asyncio.Event()

            def record(message):
                if (message.message_type == MessageType.SIGNAL and
                        message.interface == OBJECT_MANAGER and
                        message.member == 'InterfacesAdded' and message.body[0] == MODEM):
                    added.append(message)
                    received.set()

            client.add_message_handler(record)
            await client.call(Message(destination='org.freedesktop.DBus',
                path='/org/freedesktop/DBus', interface='org.freedesktop.DBus',
                member='AddMatch', signature='s',
                body=["type='signal',interface='org.freedesktop.DBus.ObjectManager'"]))
            service.export(MODEM, Modem())
            service.export(MODEM, Ussd())

            async def snapshot():
                reply = await client.call(Message(destination=service.unique_name,
                    path=ROOT, interface=OBJECT_MANAGER, member='GetManagedObjects'))
                self.assertEqual(reply.message_type, MessageType.METHOD_RETURN)
                return reply.body[0]

            self.assertNotIn(MODEM, await snapshot())
            await service.announce_modem(MODEM)
            await asyncio.wait_for(received.wait(), 2)
            objects = await snapshot()
            self.assertEqual(len(added), 1)
            self.assertEqual(added[0].path, ROOT)
            self.assertEqual(len(added[0].body[1]), 2)
            self.assertEqual(objects[MODEM][Ussd().name]['NetworkRequest'].value, 'ready')
        finally:
            client.disconnect()
            service.disconnect()


if __name__ == '__main__':
    unittest.main()
