#!/usr/bin/env python3
"""Build the Android AIDL transport for Droidian's biometry ABI.

Only public, revision-pinned interface sources are downloaded. Vendor binaries
are local build inputs; generated code and compiled libraries stay in out/.
"""
import argparse
import concurrent.futures
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

INTERFACES = "40e9f1537e308ed49e3b561ce333e3f2bb64f31e"
FPD = "1f6d7392fa6b36ec8e7e0a28afee52a6f7c23d22"
HEADERS = "refs/tags/android-16.0.0_r1"
HERE = Path(__file__).resolve().parent


def download(url, destination):
    if destination.is_file():
        return
    for attempt in range(3):
        try:
            data = urllib.request.urlopen(url, timeout=45).read()
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_suffix(destination.suffix + ".part")
            temporary.write_bytes(data)
            temporary.replace(destination)
            return
        except Exception:
            if attempt == 2:
                raise


def archive(url, cache, destination, prefix=""):
    download(url, cache)
    with tarfile.open(fileobj=io.BytesIO(cache.read_bytes())) as source:
        for member in source.getmembers():
            path = Path(member.name)
            if (not member.isfile() or path.is_absolute() or ".." in path.parts or
                    not member.name.startswith(prefix)):
                continue
            target = destination / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.extractfile(member).read())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("libs", type=Path, help="private Android system/lib64 directory")
    parser.add_argument("output", type=Path)
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    cache = args.cache or out / "source-cache"
    aidl = out / "aidl"
    headers = out / "headers/android"
    out.mkdir(parents=True, exist_ok=True)
    base = "https://android.googlesource.com/platform/hardware/interfaces/"
    interfaces = {
        "fingerprint": "biometrics/fingerprint/aidl/aidl_api/android.hardware.biometrics.fingerprint/2",
        "biometric-common": "biometrics/common/aidl/aidl_api/android.hardware.biometrics.common/3",
        "gatekeeper": "gatekeeper/aidl/aidl_api/android.hardware.gatekeeper/1",
        "keymint": "security/keymint/aidl/aidl_api/android.hardware.security.keymint/3",
        "secureclock": "security/secureclock/aidl/aidl_api/android.hardware.security.secureclock/1",
        "keymaster": "keymaster/aidl",
        "sharedsecret": "security/sharedsecret/aidl/aidl_api/android.hardware.security.sharedsecret/1",
    }
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        jobs = [pool.submit(archive, base + "+archive/" + INTERFACES + "/" + path + ".tar.gz",
                            cache / (name + ".tar.gz"), aidl, "android/")
                for name, path in interfaces.items()]
        for job in jobs:
            job.result()
    for directory in ("include_cpp", "include_platform"):
        archive("https://android.googlesource.com/platform/frameworks/native/+archive/" +
                HEADERS + "/libs/binder/ndk/" + directory + "/android.tar.gz",
                cache / (directory + ".tar.gz"), headers)
    biometry = cache / "biometry.h"
    download("https://raw.githubusercontent.com/droidian/droidian-fpd/" + FPD +
             "/src/biometry.h", biometry)
    shutil.copyfile(biometry, out / "biometry.h")

    files = {".".join(p.relative_to(aidl).with_suffix("").parts): p
             for p in aidl.rglob("*.aidl")}
    needed = {}

    def include(name):
        if name in needed:
            return
        path = files[name]
        needed[name] = path
        for dependency in set(re.findall(r"android\.hardware\.(?:[a-zA-Z_]\w*\.)*[A-Z]\w*",
                                         path.read_text())):
            while dependency not in files and "." in dependency:
                dependency = dependency.rsplit(".", 1)[0]
            if dependency in files:
                include(dependency)

    include("android.hardware.biometrics.fingerprint.IFingerprint")
    include("android.hardware.gatekeeper.IGatekeeper")
    include("android.hardware.security.sharedsecret.ISharedSecret")
    compiler = os.environ.get("AIDL", "aidl")
    subprocess.run([compiler, "--lang=ndk", "--structured", "--stability=vintf", "--version=2",
                    "--min_sdk_version=34", "-I", str(aidl), "-o", str(out / "gen"),
                    "-h", str(out / "include")] + [str(needed[k]) for k in sorted(needed)], check=True)
    vendor_aidl = HERE.parent / "compat/aidl"
    subprocess.run([compiler, "--lang=ndk", "--structured", "--stability=vintf", "--version=1",
                    "--min_sdk_version=34", "-I", str(vendor_aidl), "-o", str(out / "gen"),
                    "-h", str(out / "include"),
                    str(vendor_aidl / "vendor/xiaomi/hardware/fingerprintextension/IXiaomiFingerprint.aidl")],
                   check=True)

    ndk = Path(os.environ["ANDROID_NDK_ROOT"])
    host = "darwin-x86_64" if sys.platform == "darwin" else "linux-x86_64"
    toolchain = ndk / "toolchains/llvm/prebuilt" / host
    cxx = os.environ.get("SHENNONG_ANDROID_CXX", str(toolchain / "bin/clang++"))
    if sys.platform == "linux" and os.uname().machine == "aarch64":
        cxx = os.environ.get("SHENNONG_ANDROID_CXX", "clang++")
    resource = sorted((toolchain / "lib/clang").iterdir(), key=lambda p: int(p.name.split(".")[0]))[-1]
    library = args.libs.resolve() / "libbinder_ndk.so"
    if not library.is_file():
        parser.error("libbinder_ndk.so is missing from the private Android input")
    subprocess.run([cxx, "--target=aarch64-linux-android34", "--sysroot=" + str(toolchain / "sysroot"),
                    "-resource-dir", str(resource), "-rtlib=compiler-rt", "-unwindlib=libunwind",
                    "-std=c++17", "-stdlib=libc++", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-static-libstdc++", "-fPIC", "-shared", "-DBINDER_STABILITY_SUPPORT",
                    "-Wl,-soname,libbiometry_fp_aidl.so", "-Wl,-z,relro,-z,now", "-Wl,--no-undefined",
                    "-I", str(out), "-I", str(out / "include"), "-I", str(out / "headers"),
                    str(HERE.parent / "compat/fingerprint-aidl.cpp")] +
                   [str(p) for p in sorted((out / "gen").rglob("*.cpp"))] +
                   [str(library), "-o", str(out / "libbiometry_fp_aidl.so")], check=True)
    print(out / "libbiometry_fp_aidl.so")


if __name__ == "__main__":
    main()
