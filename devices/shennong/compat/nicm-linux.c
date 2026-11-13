// SPDX-License-Identifier: GPL-2.0-only
/* Select Qualcomm NICM's existing Linux/B2G routing path for this device.
 * Only nicmd loads this library. Linux NetworkManager owns addresses/routes;
 * modem, SIM, APN and data-call results still come from the stock services.
 */
extern int __system_property_get(const char *name, char *value);

static int equal(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static int copy_value(char *value, const char *source)
{
    int length = 0;
    if (source) {
        while (source[length] && length < 91) {
            value[length] = source[length];
            length++;
        }
    }
    value[length] = 0;
    return length;
}

int property_get(const char *key, char *value, const char *fallback)
{
    if (equal(key, "init.svc.b2g")) return copy_value(value, "running");
    int length = __system_property_get(key, value);
    return length > 0 ? length : copy_value(value, fallback);
}

/* NICM otherwise waits indefinitely for Android netd, even in Linux mode. */
void shennong_nicm_linux_routing(void)
    __asm__("_ZN4Nicm9ProxyNetd16getServiceHandleEv");

void shennong_nicm_linux_routing(void) {}
