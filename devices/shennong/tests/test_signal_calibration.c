/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include "binder_signal_policy.h"

int main(void)
{
    const int cn[] = { -125, -115, -110, -105 };
    const int duplicate[] = { -125, -115, -115, -105 };
    const int reversed[] = { -105, -110, -115, -125 };
    const int outside[] = { -141, -115, -110, -105 };
    int i;

    assert(binder_signal_rsrp_thresholds_valid(cn));
    assert(!binder_signal_rsrp_thresholds_valid(duplicate));
    assert(!binder_signal_rsrp_thresholds_valid(reversed));
    assert(!binder_signal_rsrp_thresholds_valid(outside));
    assert(binder_signal_rsrp_quality(-140, cn) == 0);
    assert(binder_signal_rsrp_quality(INT_MAX, cn) == 0);
    assert(binder_signal_rsrp_quality(INT_MIN, cn) == 0);
    assert(binder_signal_rsrp_quality(-43, cn) == 0);
    for (i = 0; i < 4; i++) {
        assert(binder_signal_rsrp_quality(cn[i] - 1, cn) == i * 25);
        assert(binder_signal_rsrp_quality(cn[i], cn) == (i + 1) * 25);
    }
    assert(binder_signal_rsrp_quality(-120, cn) == 25);
    assert(binder_signal_rsrp_quality(-113, cn) == 50);
    assert(binder_signal_rsrp_quality(-107, cn) == 75);
    assert(binder_signal_rsrp_quality(-85, cn) == 100);
    assert(binder_signal_rsrp_quality(-44, cn) == 100);
    puts("RSRP calibration: boundaries, unknowns and invalid policies passed");
    return 0;
}
