#!/usr/bin/env python3
"""Exercise the installed native Calls provider against an isolated oFono bus.

Run as the graphical desktop user with `dbus-run-session -- python3 TEST`.
The private bus replaces the modem; no test number reaches the real radio.
"""
import os
import subprocess
import tempfile
import time
from pathlib import Path

from gi.repository import Gio, GLib

XML = """<node>
<interface name="org.ofono.Manager">
 <method name="GetModems"><arg direction="out" type="a(oa{sv})"/></method>
 <signal name="ModemAdded"><arg type="o"/><arg type="a{sv}"/></signal>
 <signal name="ModemRemoved"><arg type="o"/></signal>
</interface>
<interface name="org.ofono.Modem">
 <method name="GetProperties"><arg direction="out" type="a{sv}"/></method>
 <signal name="PropertyChanged"><arg type="s"/><arg type="v"/></signal>
</interface>
<interface name="org.ofono.VoiceCallManager">
 <method name="GetCalls"><arg direction="out" type="a(oa{sv})"/></method>
 <method name="GetProperties"><arg direction="out" type="a{sv}"/></method>
 <method name="Dial"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="out" type="o"/></method>
 <signal name="CallAdded"><arg type="o"/><arg type="a{sv}"/></signal>
 <signal name="CallRemoved"><arg type="o"/></signal>
</interface>
<interface name="org.ofono.SupplementaryServices">
 <method name="GetProperties"><arg direction="out" type="a{sv}"/></method>
 <signal name="PropertyChanged"><arg type="s"/><arg type="v"/></signal>
</interface>
</node>"""


def main():
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        raise SystemExit("Run this test inside dbus-run-session")
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                  "org.freedesktop.DBus", "RequestName",
                  GLib.Variant("(su)", ("org.ofono", 4)), None,
                  Gio.DBusCallFlags.NONE, 3000, None)
    online = {"/ril_0": True, "/ril_1": False}
    powered = {"/ril_0": True, "/ril_1": True}
    dials = []
    ready = {p: 0 for p in online}
    context = GLib.MainContext.default()

    def properties(path):
        return {
            "Online": GLib.Variant("b", online[path]),
            "Powered": GLib.Variant("b", powered[path]),
            "Interfaces": GLib.Variant("as", ["org.ofono.VoiceCallManager",
                                                "org.ofono.SupplementaryServices"]),
            "Serial": GLib.Variant("s", "TEST-MODEM"),
            "Type": GLib.Variant("s", "hardware"),
        }

    def method(connection, sender, path, interface, name, args, invocation):
        if name == "GetModems":
            # Empty SIM2 comes first, reproducing the observed device failure.
            result = [(p, properties(p)) for p in ["/ril_1", "/ril_0"]]
            # ModemAdded/GetModems may precede proxy subscription. The current
            # GetProperties state is powered, but the earlier snapshot is not.
            for _, values in result:
                values["Powered"] = GLib.Variant("b", False)
            invocation.return_value(GLib.Variant("(a(oa{sv}))", (result,)))
        elif name == "GetProperties":
            result = properties(path) if interface == "org.ofono.Modem" else {}
            invocation.return_value(GLib.Variant("(a{sv})", (result,)))
        elif name == "GetCalls":
            ready[path] += 1
            invocation.return_value(GLib.Variant("(a(oa{sv}))", ([],)))
        elif name == "Dial":
            dials.append((path, args.unpack()[0]))
            # Deliberately do not create a call or access any real modem.
            def reject():
                invocation.return_dbus_error("org.ofono.Error.NotSupported", "Routing test only")
                return GLib.SOURCE_REMOVE
            if args.unpack()[0] == "5550199":
                GLib.timeout_add(300, reject)
            else:
                reject()

    info = Gio.DBusNodeInfo.new_for_xml(XML)
    for interface in info.interfaces:
        paths = ["/"] if interface.name == "org.ofono.Manager" else list(online)
        for path in paths:
            bus.register_object(path, interface, method, None, None)

    with tempfile.TemporaryDirectory(prefix="shennong-dual-sim-") as temporary:
        folder = Path(temporary)
        environment = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"],
                           XDG_CONFIG_HOME=str(folder / "config"), XDG_DATA_HOME=str(folder / "data"),
                           GSETTINGS_BACKEND="memory", G_MESSAGES_DEBUG="all")
        log = folder / "calls.log"
        with log.open("w") as output:
            process = subprocess.Popen(["gnome-calls", "--gapplication-service", "--plugins=ofono", "-v"],
                                       env=environment, stdout=output, stderr=subprocess.STDOUT)

            def wait_for(predicate, label):
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    while context.pending():
                        context.iteration(False)
                    if predicate():
                        return
                    if process.poll() is not None:
                        break
                    time.sleep(0.01)
                raise AssertionError(label + "\n" + log.read_text(errors="replace")[-6000:])

            def state(path, key, value):
                (online if key == "Online" else powered)[path] = value
                bus.emit_signal(None, path, "org.ofono.Modem", "PropertyChanged",
                                GLib.Variant("(sv)", (key, GLib.Variant("b", value))))

            def dial(number, origin=None):
                path = origin.removeprefix("ofono:") if origin else next(
                    p for p in online if online[p] and powered[p])
                wait_for(lambda: ready[path] >= log.read_text().count(
                    "Adding oFono Origin with path `" + path + "'"),
                    "Voice proxy initialization did not complete")
                old_count = len(dials)
                action = "dial-tel" if origin else "dial"
                parameter = GLib.Variant("(ss)", (number, origin)) if origin else GLib.Variant("s", number)
                bus.call_sync("org.gnome.Calls", "/org/gnome/Calls", "org.gtk.Actions", "Activate",
                              GLib.Variant("(sava{sv})", (action, [parameter], {})), None,
                              Gio.DBusCallFlags.NONE, 3000, None)
                wait_for(lambda: len(dials) == old_count + 1, "Expected exactly one routed call")
                return dials[-1]

            try:
                wait_for(lambda: "Adding oFono Origin with path `/ril_0'" in log.read_text(), "Online SIM1 was not discovered")
                assert "Adding oFono Origin with path `/ril_1'" not in log.read_text(), "Offline SIM2 was offered for dialing"
                assert dial("5550100") == ("/ril_0", "5550100")
                state("/ril_1", "Online", True)
                wait_for(lambda: "Adding oFono Origin with path `/ril_1'" in log.read_text(), "SIM2 did not become available")
                assert dial("5550101", "ofono:/ril_0") == ("/ril_0", "5550101")
                assert dial("5550102", "ofono:/ril_1") == ("/ril_1", "5550102")
                state("/ril_0", "Online", False)
                wait_for(lambda: "Removing unavailable oFono Origin with path `/ril_0'" in log.read_text(), "Offline SIM1 was not removed")
                assert dial("5550103") == ("/ril_1", "5550103")
                state("/ril_0", "Online", True)
                wait_for(lambda: log.read_text().count("Adding oFono Origin with path `/ril_0'") == 2, "SIM1 did not return")
                assert dial("5550104", "ofono:/ril_0") == ("/ril_0", "5550104")
                state("/ril_1", "Powered", False)
                wait_for(lambda: "Removing unavailable oFono Origin with path `/ril_1'" in log.read_text(), "Powered-off SIM2 was not removed")
                assert dial("5550105") == ("/ril_0", "5550105")
                bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                              "org.freedesktop.DBus", "ReleaseName",
                              GLib.Variant("(s)", ("org.ofono",)), None,
                              Gio.DBusCallFlags.NONE, 3000, None)
                wait_for(lambda: "Ofono vanished from D-Bus" in log.read_text(),
                         "Provider did not observe modem backend stopping")
                bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                              "org.freedesktop.DBus", "RequestName",
                              GLib.Variant("(su)", ("org.ofono", 4)), None,
                              Gio.DBusCallFlags.NONE, 3000, None)
                wait_for(lambda: log.read_text().count("Adding oFono Origin with path `/ril_0'") == 3,
                         "SIM1 did not return after native backend restart")
                assert dial("5550106") == ("/ril_0", "5550106")
                old_count = len(dials)
                for _ in range(2):
                    bus.call_sync("org.gnome.Calls", "/org/gnome/Calls", "org.gtk.Actions", "Activate",
                                  GLib.Variant("(sava{sv})", ("dial-tel", [GLib.Variant("(ss)",
                                  ("5550199", "ofono:/ril_0"))], {})), None,
                                  Gio.DBusCallFlags.NONE, 3000, None)
                wait_for(lambda: "Presenting the existing call instead of dialing it again" in log.read_text(),
                         "Duplicate pending dial was not rejected")
                assert len(dials) == old_count + 1, "Duplicate dial reached the modem"
                assert "invalid property id" not in log.read_text()
                print("PASS: single-SIM selection, both independent SIM IDs, online/offline changes, powered-off exclusion, stale snapshot refresh, native backend restart, duplicate dial suppression")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
