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
namespaces. This still requires a real kernel/module ABI check and boot test;
it is not a claim of support for the broader Halium profile.

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
Python 3 and `gpgv`. Build the config packages and an upstream Droidian rootfs:

```sh
sudo bash devices/shennong/tools/build-rootfs.sh
```

This exports a tar archive, not a generic flashable zip. It installs the
packaged HWCOMPOSER configuration, defaults to Simplified Chinese and the
Asia/Shanghai timezone, and creates `droidian` with password `123`. Locale
preferences remain changeable through the desktop's own settings.

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
Droidian booted with working USB NCM/SSH, Synaptics input, the stock ADSP
battery channel and the Adreno GPU device. This does not yet establish that
the camera, cellular, Wi-Fi or accelerated desktop work.

The first container attempt exposed an important root-handoff issue: a host
chroot alone left the mount namespace rooted in initramfs. Android APEX's
`setns()` then changed `/` back to that old root and lost `/bootstrap-apex`.
The B initramfs now moves the Linux root onto `/` before entering it. The
next real boot passed that failure and started Android services.

APEX then rejected duplicate versioned mounts. The container configuration
now inherits the dedicated root's APEX tree once, omitting the generic second
`/apex` bind. After starting this configuration the USB management link became
unresponsive; its cause and the stability of the container remain under
investigation. Read the persistent boot/kernel records from REC before
claiming this change has fixed APEX startup.

Physical boot/display validation is in progress. This is a development port,
not a verified solution to the visible tearing problem.
