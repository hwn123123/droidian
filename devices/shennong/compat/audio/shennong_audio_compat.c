// SPDX-License-Identifier: GPL-2.0-only
/* The stock SPF driver attempts population once, before Android PDR is ready.
 * Complete that same hardware handoff after the container has initialized.
 * Keep the stock DSP, ASoC drivers, device tree and userspace audio policy.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>

extern bool spf_core_is_apm_ready(int timeout_ms);

static int __init shennong_audio_compat_init(void)
{
	struct device_node *node;
	struct device *dev;
	int ret;

	node = of_find_compatible_node(NULL, NULL, "qcom,spf-core-platform");
	if (!node)
		return -ENODEV;
	dev = bus_find_device_by_of_node(&platform_bus_type, node);
	if (!dev) {
		of_node_put(node);
		return -ENODEV;
	}
	if (!spf_core_is_apm_ready(5000)) {
		dev_err(dev, "Droidian audio: stock DSP is not ready\n");
		ret = -EAGAIN;
	} else {
		/* Already populated DT children are skipped by the native OF API. */
		ret = of_platform_populate(node, NULL, NULL, dev);
		if (ret)
			dev_err(dev, "audio child population failed: %d\n", ret);
	}
	put_device(dev);
	of_node_put(node);
	return ret;
}

/* Children belong to the existing SPF parent, not to this one-shot handoff. */
static void __exit shennong_audio_compat_exit(void) { }

module_init(shennong_audio_compat_init);
module_exit(shennong_audio_compat_exit);
MODULE_LICENSE("GPL v2");
MODULE_SOFTDEP("pre: spf_core_dlkm");
MODULE_DESCRIPTION("Shennong stock SPF late audio initialization");
