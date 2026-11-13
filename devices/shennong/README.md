# Droidian for Xiaomi 14 Pro (shennong)

This port is maintained on `hwn123123/droidian`, branch `droidian-14pro`.
The first milestone is a real HWCOMPOSER display path: Halium 14's Android
userspace runs the stock Composer 3 service, while Droidian's libhybris and
patched wlroots present Phosh through that service.

## Confirmed prerequisites (2026-11-12)

Read-only queries of the running slot-A Android system returned VNDK 34,
vendor SDK 34 and `android.hardware.graphics.composer3` version 2. The Android
system release is 16; its vendor interface is Android 14. Select API 34 from
the vendor interface, not the system release or the kernel filename.

The stock kernel is `6.1.138-android14-11-g0c3d559bcd85-ab14529422`. It lacks
PID/IPC namespaces, devtmpfs, file handles, virtual terminals and some cgroup
controllers needed by the standard Droidian session/container. Merely copying
a Droidian rootfs onto the existing Kali kernel is insufficient.
`kernel/halium.config` records the broader upstream Halium feature set.
The first build with those features completed, but failed the stock modules'
symbol CRC checks. It must not be deployed.

The initial display milestone uses the smaller `kernel/display.config`.
It preserves stock SysV IPC, user-namespace and cgroup-controller settings
while adding PID namespaces and the facilities needed by the standard display
session. The device's LXC config inherits the host IPC/user context through
the upstream `lxc.namespace.keep` setting and retains separate PID/mount
namespaces. All 1,118 captured modules passed the kernel import/CRC checks,
and the device subsequently booted this display profile. This does not claim
support for the broader Halium profile.

Droidian's `next` snapshot has API 34 metapackages, Android 14 GSI and the
AIDL-capable libhybris build. The `current` snapshot inspected on 2026-11-12
does not have the API 34 package set. The image recipes use `next` explicitly.

## Fetch and verify build inputs

From this repository on Linux with Python 3 and `gpgv` installed:

```sh
python3 devices/shennong/tools/fetch-inputs.py \
  --output out/shennong/inputs --download
```

The helper verifies the detached archive signature against the upstream
submodule's keyring, verifies both package indexes, then pins exact package
versions and SHA256 values. Package archives and device captures stay in the
ignored `out/` directory. No private firmware, keys or identifiers belong in
Git. The selected archives are bring-up inputs, not a dependency resolver or
a complete root filesystem.

Inspect an Android properties capture and a kernel configuration:

```sh
python3 devices/shennong/tools/check-prerequisites.py \
  --properties out/shennong/evidence/android-api.txt \
  --config out/shennong/evidence/stock-running.config.gz
```

A nonzero exit status means the vendor does not match or kernel changes are
still required. The check performs no device writes.

## Deployment layout

The existing 200 GiB `linux_root` partition is the Linux root target. Preserve
Android's `userdata`, slot A and both REC images. Deploy boot artifacts only
to the named B partitions through the existing authenticated REC installer,
after testing their kernel/module compatibility. The upstream generic
`flash_all.sh` and recovery zip target the standard single-system layout and
must not be used on this custom dual-system device.

The original Kali port remains a reference for the working module order,
touch input, USB connection, QUP firmware and REC dispatch. Its forced Pixman
renderer and desktop patches are not part of this display validation.

## Build

The arm64 Linux builder needs `debos`, `debootstrap`, `debhelper`, `fakeroot`,
Clang/LLD, an Android NDK sysroot, binutils, Python 3 and `gpgv`. Build the
config packages and an upstream Droidian rootfs:

```sh
sudo bash devices/shennong/tools/build-rootfs.sh
```

This exports a tar archive, not a generic flashable zip. It installs the
packaged HWCOMPOSER configuration, defaults to Simplified Chinese and the
Asia/Shanghai timezone, and creates `droidian` with password `123`. Locale
preferences remain changeable through the desktop's own settings.
The system locale is `zh_CN.UTF-8`, with `LANGUAGE=zh_CN:zh` for translated
applications. These are image defaults in `/etc/default/locale`; there is no
login or boot task forcing the language/timezone back after a user changes it.

### Native phone desktop

The phone home is an isolated patch against Droidian Phosh revision
`bee1861911b0cf75f50ab00cea5a84ed98d9c32f`, not a second launcher or a startup
script. Its Debian version is the upstream version plus `+shennong4`.
Build it inside a matching arm64 Droidian `next` build environment:

```sh
sudo apt-get install build-essential devscripts equivs
sudo mk-build-deps -ir -t 'apt-get -y --no-install-recommends' \
  -Pnodoc,nocheck /path/to/matching-phosh/debian/control
sudo bash devices/shennong/tools/build-phosh.sh
```

Keep the repository and its output directory accessible inside the build
environment. The helper pins the shell and both subprojects, applies the
device patch and exports four runtime packages to `out/shennong/ui-packages/`.
Run this before `build-device-image.sh`; offline image preparation installs
these packages and checks the appearance inputs against `ui-packages.json`.

The main page has a clock and favorite launchers. Swipe left for the remaining
apps and right to return. The first four native Phosh favorites form a fixed
dock; the rest appear on the main page. Long-press and drag an icon onto another
to change its order. Long-press and release in place opens Phosh's own app menu
for favorites, folders and available software actions. App order is stored in
`mobi.phosh.shell.home app-order`; favorites remain in `sm.puri.phosh favorites`.
New applications follow the saved order; uninstalled applications disappear
through the existing app model. Home and recent tasks are separate views, so
running app thumbnails do not squeeze the desktop. Tap the persistent bottom
handle to return from an app to the home page. The native task carousel,
notifications, quick settings, lockscreen and compositor remain in use.

The packaged GSettings overrides supply a dark teal appearance, Papirus icons,
Inter text with the distribution's Noto Chinese fallback and the Tide wallpaper.
They are defaults: later changes in Phosh/GNOME settings take precedence and
are not reset at login or boot. Wallpaper provenance and its generation prompt
are included alongside the asset in the adaptation package.

### Panel brightness

For the primary `HWCOMPOSER-1` output, Phosh first tries its existing Linux
sysfs/logind backlight backend. The stock Lights AIDL service advertises a
backlight and accepts updates without driving this panel; previously the
slider changed only libdroid's saved value. The native backend uses the
kernel's real range and Phosh's normal brightness curve, with logind handling
permissions. Android remains the fallback when no native backlight exists.
Backend failures propagate instead of being reported as successful updates.

On 2026-11-14, changing the actual quick-settings slider produced increasing
kernel levels across the range, up to 4095. A real power-key off/on cycle
preserved the selected level, and the owner confirmed visible brightness
changes. Brightness storage remains with the standard systemd-backlight
service; there is no independent brightness daemon or periodic writer.

### Wi-Fi hardware handoff

The native `shennong-wifi.service` loads the captured stock
`qca_cld3_kiwi_v2` module after vendor/ADSP/container initialization and writes
the existing CNSS `fs_ready` handoff. The supplicant is ordered after this
hardware stage. NetworkManager and the distribution's wpa_supplicant keep
ownership of scanning, saved networks, authentication and DHCP; there is no
independent reconnection loop or parallel Android Wi-Fi controller.

The firmware directory contains links to the original vendor WLAN INI and
the read-only persist MAC file. The early ramdisk's `/vendor/firmware` mount
hides the original vendor symlinks, so the links in the native firmware search
directory are required. The distribution's signed `wireless-regdb` package
supplies the standard Linux regulatory database. Proprietary configuration
and calibration contents are not copied into Git. The unused Android Wi-Fi
HAL is disabled rather than repeatedly failing a request for module-loading
capabilities that belong to the host.

On 2026-11-14 the owner-confirmed brightness fix survived a power-key off/on
cycle. Wi-Fi subsequently exposed its station interface and scanned real
2.4 GHz and 5 GHz access points. Hardware initialization and scanning also
passed after a fresh boot with adaptation 0.1.10. An actual connection to an
owner-selected network, Internet access and reconnect remain pending.

Build the pinned 6.1.138 source with the captured stock config:

```sh
bash devices/shennong/tools/build-kernel.sh \
  out/shennong/kernel/common-0c3d559bcd85.tar.gz \
  out/shennong/evidence/stock-running.config.gz
```

The archive URL and checksum are recorded in `kernel/source.json`. The
builder uses native arm64 LLVM 17, adds the container configuration fragment,
and disables export trimming because the Android build's generated ABI
whitelist is absent. The isolated host-tool patch fixes a const pointer in
libbpf for the build host's newer libc. It changes no phone driver behavior.
Original driver signatures are not removed or patched. A compiled image is
not yet cleared for deployment: check the real module CRCs with
`tools/check-module-abi.py`, including early vendor-ramdisk modules.

The kernel builder defaults to the `display` profile. Set
`SHENNONG_KERNEL_PROFILE=halium` only for work on the broader feature set.
Its outputs are separated as `kernel-display-build/` and
`kernel-halium-build/`. The checker follows Linux 6.1's versioned-module
semantics: it validates actual import CRCs and vermagic features, while
reporting release-string differences separately. It never rewrites the CRCs
or forces a module load.

`tools/capture-vendor.py` captures mounted stock HAL images through authorized
root ADB. It checks the device, VNDK, read-only mount status, lengths and
device/local SHA256 values. These private inputs stay in `out/`; they are
not flashed back to Android's partitions.

Finish the archive offline, including the locally captured private vendor
images, matching modules and a host SSH public key:

```sh
sudo bash devices/shennong/tools/build-device-image.sh \
  out/shennong/droidian-shennong-rootfs.tar.gz out/shennong/host.pub
```

The result has the existing 200 GiB ext4 geometry. The Debian adaptation
package owns hardware setup, mount ordering and the USB management link;
desktop settings remain under Phosh. No Android userdata mount is used.
Image preparation expands the distribution's private `android-rootfs.img` to
2 GiB using the native ext4 tools while it is unmounted. The distributed
432 MiB filesystem has only 1,664 inodes; exhausting them prevents LXC from
creating `.lxc_keep` and stops both display and USB. This is a sparse file
inside the dedicated Linux root, with no change to the device partition layout.
LXC startup errors use its native syslog option and the bounded system journal.
Droidian's existing `droidian_boot_completed.service` calls the distribution's
`android_bootctl mark-boot-successful` after the desktop starts. This commits
the current slot through BootControl; without it, repeated normal B boots
exhaust the bootloader's retry counter and fall back to slot A. No extra
boot-monitor process or independent slot-control implementation is installed.
Image preparation also builds `compat/binder-no-secctx.c` against the image's
own Bionic runtime and installs its output in the private vendor overlay.
`install-binder-compat.sh` mounts that Android image read-only for the build;
no proprietary libraries or compiled compatibility binaries are stored in Git.
Set `ANDROID_NDK_ROOT` when preparing the device image: the stock USB port
callback client is built from `compat/usb-framework.cpp` against that NDK and
the captured Android system's Binder NDK library. On an arm64 Linux builder,
native Clang uses the NDK sysroot, CRT and runtime libraries; no x86 compiler
execution is required. Pass the NDK variable through `sudo` explicitly.

The cellular transport additionally needs the stock tethering APEX's arm64
connectivity, DNS helper and C++ libraries. Stage these saved local inputs
before preparing the device image:

```sh
python3 devices/shennong/tools/stage-cellular-runtime.py \
  --source-lib64 /path/to/saved/stock/apex/com.android.tethering/lib64 \
  --output out/shennong/private-cellular
```

These binaries and their checksum manifest stay outside Git. The image
installer verifies them and builds `compat/nicm-linux.c` from source. Only
the stock `nicmd` service loads this adapter, which selects Qualcomm's
existing Linux routing path; NetworkManager owns addresses and routing.
IPA/RMNET and TIPC are loaded on the host before the Android container.
The container shares the host network namespace so Radio and NICM can use
the same modem transport and data interfaces. It retains its PID/mount
namespaces. Volatile property files are recreated on container-only restarts;
persistent Android properties and user data remain in the dedicated root.

The pinned Droidian AIDL plugin sends an empty traffic descriptor in its
unpatched data-call request. The isolated patch in
`patches/ofono-binder-plugin/` supplies the selected APN as DNN and calculates
the parcelable size, following Android's DataProfileManager. Ordinary APN
requests also permit the default URSP rule, as Android DataNetwork does.
Build it in an arm64 Droidian build root with `build-essential`, `pkg-config`,
`libglib2.0-dev`, `libgbinder-dev`, `libgbinder-radio-dev`, `ofono-dev` and
`libglibutil-dev` installed:

```sh
sudo bash devices/shennong/tools/build-ofono-plugin.sh /path/to/droidian-build-root
```

The helper pins upstream commit `9b9e8bd2ffc8a6ba482d6daf7171fd84ba82c3b8`,
runs its tests and builds a `+shennong2` Debian package. Also run
`sudo bash devices/shennong/tools/build-ofono2mm.sh` to package the isolated
address-prefix, network-port and late SIM-property refresh fixes against the pinned
upstream modem bridge. It produces a `+shennong15` package. Device image preparation
requires both packages.
For a rebuild with inputs already cached, set `SHENNONG_OFFLINE=1`; the helper
still verifies the archive signature and all cached package hashes.
Changes to the upstream plugin are kept as a separate patch; the stock
Android Radio binaries and modem firmware are used unchanged. Both SIM slots use stable AIDL on `/dev/binder`.
The first initialized SIM is selected once through oFono's own default;
subsequent SIM and APN choices remain under the desktop's normal controls.
UPower retains its upstream service credentials and sandbox, with only
`PrivateUsers` disabled because this stock-compatible kernel has no user
namespaces.
The packaged ModemManager bridge explicitly starts after oFono. Its upstream
unit required oFono but did not order startup, allowing the bridge to enumerate
the radio before the SIM interface was ready.

Mobile connection policy belongs to NetworkManager. The packaged GSM keyfile
uses `gsm.auto-config=true` and the distribution's provider database, with no
device-specific SIM identifier or fixed carrier APN. Saved custom profiles
take priority. Phosh/GNOME Settings can change the same standard connection.
The bridge implements the normal Simple.Connect enable step, propagates errors
and bounds registration waits. It serializes modem power changes, and reports
the actual oFono state. NetworkManager handles reconnection; the bearer has no
separate retry loop or background reconnect after an explicit disconnect.
Modem and SIM subscriptions are installed before reading their initial state.
Each late slot refreshes the earlier `GetModems` snapshot and publishes one
complete modem object on the manager's ObjectManager path, so NetworkManager
can discover it even after the first slot has acquired the bus name. This is
implemented inside the existing bridge; SIM/bearer object paths and the
NetworkManager service remain unchanged.
The bridge emits property updates before `StateChanged`, and refreshes the
3GPP/SIM properties before announcing a modem-state transition. NetworkManager
uses libmm-glib's cached state and operator code in that callback; sending the
transition first leaves native automatic APN selection waiting indefinitely.
Before its first publication, each slot waits for the SIM's present/PIN result
for up to 30 seconds. This prevents a transient SIM_MISSING state from skipping
NetworkManager's first radio-enable request. Empty slots retain their actual
SIM_MISSING result when that bounded initialization window ends.
The unused direct-oFono pseudo devices remain strictly unmanaged, including
when the desktop's global mobile-data switch changes.

USB defaults to NCM shared networking at `192.168.66.1/24`. Its fixed local
SSH address and NetworkManager's shared-mode DHCP/DNS/NAT are enabled without
testing cellular registration, dial state or Internet reachability. Connecting
the Mac with a manual `192.168.66.2/24` address and no USB gateway keeps its
existing Wi-Fi route. The Android port HAL owns Type-C events; the Linux host
is the only ConfigFS/NCM and network owner. The device callback client follows
the frozen [AOSP IUsb interface](https://android.googlesource.com/platform/hardware/interfaces/+/eee5499ba8381b50a29a541c2077b040a642fa18/usb/aidl/android/hardware/usb/IUsb.aidl).
The fixed address and SSH were verified after a real reboot on 2026-11-13.
An earlier package left a same-UUID `.dpkg-old` connection at the former
address; the device-package migration removes that specific obsolete backup.
MTP, OTG peripherals and USB role-switch controls are not yet validated.
`build-boot-images.sh` repacks captured B boot images and preserves their REC
dispatcher. Neither offline builder accesses a phone partition.

Before REC installation, capture and validate the first and last six sectors
of `/dev/block/sda` using `check-partition-layout.py`. Some REC SELinux domains
deny the disk-geometry ioctl used by `sgdisk`; a warning from that tool alone
does not establish GPT corruption. The validator checks both header/table
CRCs, their agreement, all partition bounds, and the existing userdata/Linux
boundary. The installer compares the validated sector hashes before and
after writing, and never writes a partition table.

`deploy-from-recovery.py` transfers a checksummed payload through authenticated
ADB to a one-connection receiver bound to loopback inside REC. The payload
must include `GPT-SHA256SUMS` for `gpt-primary.current` and
`gpt-backup.current`, the partition-preservation manifest, the B boot images,
the sparse root image and `install.sh`. `PAYLOAD-SHA256SUMS` covers those
files. The REC installer verifies the dedicated root and B boot readback,
then compares the preservation manifest again. It leaves the device in REC;
switching to B is a separate action after installation succeeds.

## Bring-up status

The adaptation packages and the display kernel built successfully.
The display kernel's 53,581 imported kernel-symbol checks across 1,118
captured modules (including both early vendor ramdisks) passed with zero CRC
or vermagic-feature mismatches. The broader Halium profile failed and is
excluded from deployment. The rootfs and B boot images are built, and the
offline service dependency check passed. The account preparation follows
Droidian's current desktop UID mapping. REC validates Linux executable mode
bits and ELF headers without requesting permission to execute those binaries
under REC's Android SELinux policy.

The dedicated Linux root and B boot images were installed through REC. All
preserved partition hashes and both GPT-sector captures matched afterwards.
Droidian initially booted with working USB NCM/SSH, Synaptics input, the stock
ADSP battery channel and the Adreno GPU device. Display and cellular results
from the later integration are recorded below.

The first container attempt exposed an important root-handoff issue: a host
chroot alone left the mount namespace rooted in initramfs. Android APEX's
`setns()` then changed `/` back to that old root and lost `/bootstrap-apex`.
The B initramfs now moves the Linux root onto `/` before entering it. The
next real boot passed that failure and started Android services.

APEX rejected duplicate versioned mounts. The container configuration now
inherits the dedicated root's APEX tree once, omitting the generic second
`/apex` bind. Real container testing subsequently reached `apexd.status=ready`.
Linux owns driver loading, system time and the management network; the Android
container drops the corresponding capabilities. The first display milestone
used a separate network namespace; cellular integration now shares the host
network for NICM and RMNET. The start helper verifies the required
host display/input/ADSP drivers before delivering the vendor's module-ready
property. This is not validation of every vendor peripheral.

The stock vendor service manager requested Binder security contexts, but the
SELinux-disabled Linux host cannot supply them. The kernel rejected calls
with `EOPNOTSUPP` at the security-context conversion, preventing
`display.qservice` registration. The device compatibility library removes
only that context-manager request flag, only when explicitly opted in through
the device's vendor init override. It forwards all other ioctl arguments
unchanged. The original service binary and vendor Binder protocol are kept;
substituting the framework service manager failed the vendor parcel format.
No kernel Binder patch or proprietary binary modification is involved.

After this change the stock composer opened DRM and reported the native
1440x3200 output at 60 Hz. The EGL subdriver also needs `vendor/lib64/egl` in
the libhybris search path. Early-ramdisk firmware hides the vendor firmware
directory, so the device mount helper retains the raw vendor firmware as an
additional kernel search directory. The GPU then initialized successfully:
EGL 1.5, 72 configurations, OpenGL ES 3.2 and Adreno 750. Phoc started its
GLES2 renderer and the Phosh session instead of falling back to Pixman.

On 2026-11-12, a real B-slot boot automatically established USB SSH, started
the Android container and opened the Phosh desktop. The owner confirmed that
the physical display works and the horizontal line seen with Kali no longer
appears in this initial test. Touch interaction also works. This validates
the new display path; longer-term display, suspend and peripheral testing
remain separate work.

A live package upgrade had unexpectedly restarted the hardware units and
disconnected USB. Package scripts now leave these units running on upgrades,
and this layout's LXC stop override avoids generic host power-control and
super-mapper teardown. The corrected package was installed without losing
USB or restarting the desktop. Persistent journal records are bounded to
64 MiB; hardware errors are not filtered out.

On 2026-11-13, the AIDL telephony path recognized both slots and the inserted
SIM, registered on China Mobile NR, and completed a real data call. The stock
Radio response supplied the IPv4 address, mask, gateway and DNS. NetworkManager
activated that connection, installed its route and DNS, and the device received
public ICMP replies, resolved names and fetched an HTTP page over cellular.
The modem bridge now preserves the real prefix instead of reporting `/0`,
and reports RMNET interfaces as network ports. Its late-slot event handler
uses the received properties and serializes exports, avoiding a missed SIM
when the two slots finish initialization at different times.

The Android application policy service repeatedly added identical firewall
hooks while waiting for Android framework services. Its stock disable property
stops this behavior; NICM and the modem data plane stay active. USB sharing
continues to use NetworkManager's standard DHCP/DNS/NAT independently of data
registration. The cellular setup is wanted by the Android container, but a
cellular setup failure does not prevent the USB/display services from starting.

The native automatic APN profile completed a real IPv4 connection in the live
upgrade tests, and an explicit disconnect remained disconnected after removing
the bridge's autonomous reconnect. A later package also serializes radio power
operations. Reboot logs exposed a separate failure: LXC could not create
`.lxc_keep` because the minimized Android root image had no free inodes.
Offline ext4 expansion restored approximately 5,000 free inodes; new image
builds reserve this space automatically. Subsequent ordinary boots restored
USB and Phosh automatically. The final bridge also passed a boot starting
from powered-off radios: NetworkManager selected the provider's APN, activated
the actual RMNET interface with its reported `/29` prefix, and fetched HTTP
200/204 pages. A bounded initial SIM probe, atomic modem publication, and
property-before-state notifications fix the separate cold-start races.

The isolated ObjectManager regression can be run against the installed bridge:

```sh
dbus-run-session -- python3 devices/shennong/tests/test_modem_publication.py /usr/lib/ofono2mm
```

It checks that incomplete objects stay out of snapshots and exactly one
complete announcement is emitted, including asynchronous properties.

This remains a development port. These cellular checks cover the inserted SIM
and IPv4 data. Dual-SIM data switching, IPv6, calls/IMS, messaging, Wi-Fi, audio,
cameras, charging and suspend still need their own hardware validation.
