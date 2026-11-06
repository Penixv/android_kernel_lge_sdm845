/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _USB_DAC_DIRECT_H
#define _USB_DAC_DIRECT_H

#include <linux/types.h>

#ifdef CONFIG_USB_DAC_DIRECT
bool usb_dac_direct_route_locked(void);
#else
static inline bool usb_dac_direct_route_locked(void)
{
	return false;
}
#endif

#endif /* _USB_DAC_DIRECT_H */
