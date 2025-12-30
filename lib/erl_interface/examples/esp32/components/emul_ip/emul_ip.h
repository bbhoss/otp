/*
 * QEMU OpenCores Ethernet interface for ESP32
 */

#ifndef _EMUL_IP_H_
#define _EMUL_IP_H_

#include "esp_err.h"

/* Check if running in QEMU */
int is_running_qemu(void);

/* Initialize QEMU Ethernet (only works in QEMU) */
esp_err_t qemu_eth_init(void);

/* Wait for network interface to be ready */
esp_err_t qemu_eth_wait_ready(int timeout_ms);

#endif /* _EMUL_IP_H_ */
