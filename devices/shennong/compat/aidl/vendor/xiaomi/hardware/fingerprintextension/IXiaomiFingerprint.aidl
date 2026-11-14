// SPDX-License-Identifier: Apache-2.0
// Public Binder ABI exposed by the stock shennong fingerprint extension.
// Transaction 1 is extCmd(int, int), returning a signed status integer.
package vendor.xiaomi.hardware.fingerprintextension;

@VintfStability
interface IXiaomiFingerprint {
    int extCmd(int command, int value);
}
