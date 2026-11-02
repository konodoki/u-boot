// SPDX-License-Identifier: GPL-2.0+
/* BXI Ground Station: recovery button connected to SARADC_IN0. */

#include <adc.h>
#include <env.h>
#include <stdio.h>
#include <linux/delay.h>

#define RECOVERY_ADC_DEVICE	"saradc@fe720000"
#define RECOVERY_ADC_CHANNEL	0
#define RECOVERY_ADC_MAX	30
#define RECOVERY_SAMPLES	3
#define RECOVERY_SAMPLE_DELAY_MS	5

/*
 * The common Rockchip code checks channel 1 and resets into BootROM download.
 * This board handles channel 0 in rk_board_late_init() and stays in U-Boot.
 */
int rockchip_dnl_key_pressed(void)
{
	return false;
}

static bool recovery_key_pressed(void)
{
	unsigned int value;
	int i, ret;

	for (i = 0; i < RECOVERY_SAMPLES; i++) {
		ret = adc_channel_single_shot(RECOVERY_ADC_DEVICE,
					      RECOVERY_ADC_CHANNEL, &value);
		if (ret) {
			printf("Recovery: SARADC_IN0 read failed (%d), continuing normal boot\n",
			       ret);
			return false;
		}

		/* The button pulls the otherwise pulled-up input to ground. */
		if (value > RECOVERY_ADC_MAX)
			return false;

		if (i + 1 < RECOVERY_SAMPLES)
			mdelay(RECOVERY_SAMPLE_DELAY_MS);
	}

	return true;
}

int rk_board_late_init(void)
{
	int ret;

	if (!recovery_key_pressed())
		return 0;

	puts("Recovery button held (SARADC_IN0): entering RockUSB on eMMC 0\n");

	/* If RockUSB fails or is cancelled, stop at the prompt, not Linux. */
	ret = env_set("bootdelay", "-1");
	if (ret)
		return ret;

	/* One-shot, RAM-only override; never save this to the SPI environment. */
	return env_set("preboot", "setenv preboot; rockusb 0 mmc 0");
}
