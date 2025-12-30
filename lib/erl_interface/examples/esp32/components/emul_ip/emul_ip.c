/*
 * OpenCores Ethernet MAC driver for QEMU ESP32
 * Updated for ESP-IDF v5.x using esp_netif
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "lwip/netif.h"
#include "lwip/tcpip.h"
#include "lwip/ip_addr.h"
#include "netif/etharp.h"

static const char *TAG = "qemu_eth";

/* Check if running in QEMU by detecting OpenCores Ethernet MAC
 * The MAC registers should be accessible if QEMU is providing open_eth */
int is_running_qemu(void)
{
    /* Try reading OpenCores Ethernet MODER register */
    volatile uint32_t *oc_moder = (volatile uint32_t *)0x3ff69000;

    /* Try writing and reading back a test pattern
     * On real hardware this would access undefined memory/peripheral */
    uint32_t orig = *oc_moder;

    /* Try to reset the MAC by writing to MODER */
    *oc_moder = 0x0000A000;  /* Reset bit + some flags */
    uint32_t readback = *oc_moder;

    /* Restore original (may not matter in QEMU) */
    *oc_moder = orig;

    /* If we can read sensible values, we're likely in QEMU with open_eth */
    if (readback != 0 && readback != 0xFFFFFFFF) {
        ESP_LOGI(TAG, "Running in QEMU (OpenCores Ethernet detected)");
        return 1;
    }

    /* Alternative: Check old magic location (some QEMU versions) */
    volatile int *qemu_test = (volatile int *)0x3ff005f0;
    if (*qemu_test == 0x42) {
        ESP_LOGI(TAG, "Running in QEMU (magic detected)");
        return 1;
    }

    return 0;
}

/* External ethoc_init from lwip_ethoc.c */
extern err_t ethoc_init(struct netif *netif);

/* The network interface */
static struct netif qemu_netif;
static esp_netif_t *esp_qemu_netif = NULL;

/* lwIP input function wrapper */
static void qemu_netif_input(void *h, void *buffer, size_t len, void *l2_buff)
{
    struct netif *netif = h;
    struct pbuf *p = (struct pbuf *)buffer;
    if (netif->input(p, netif) != ERR_OK) {
        pbuf_free(p);
    }
}

/* Initialize QEMU OpenCores Ethernet */
esp_err_t qemu_eth_init(void)
{
    if (!is_running_qemu()) {
        ESP_LOGW(TAG, "Not running in QEMU, skipping OpenCores Ethernet init");
        return ESP_ERR_NOT_SUPPORTED;
    }

    ESP_LOGI(TAG, "Initializing OpenCores Ethernet for QEMU...");

    ip4_addr_t ipaddr, netmask, gw;

    /* Use DHCP-like IP that QEMU user-net expects */
    IP4_ADDR(&gw, 10, 0, 2, 2);      /* QEMU gateway */
    IP4_ADDR(&ipaddr, 10, 0, 2, 15); /* Our IP */
    IP4_ADDR(&netmask, 255, 255, 255, 0);

    /* Add the interface to lwIP */
    struct netif *nif = netif_add(&qemu_netif, &ipaddr, &netmask, &gw,
                                   NULL, ethoc_init, tcpip_input);
    if (nif == NULL) {
        ESP_LOGE(TAG, "netif_add failed");
        return ESP_FAIL;
    }

    netif_set_default(&qemu_netif);
    netif_set_up(&qemu_netif);

    ESP_LOGI(TAG, "OpenCores Ethernet initialized");
    ESP_LOGI(TAG, "IP: " IPSTR, IP2STR(&ipaddr));
    ESP_LOGI(TAG, "Gateway: " IPSTR, IP2STR(&gw));

    return ESP_OK;
}

/* Wait for network to be ready */
esp_err_t qemu_eth_wait_ready(int timeout_ms)
{
    int waited = 0;
    while (waited < timeout_ms) {
        if (netif_is_up(&qemu_netif) && netif_is_link_up(&qemu_netif)) {
            return ESP_OK;
        }
        vTaskDelay(pdMS_TO_TICKS(100));
        waited += 100;
    }
    return ESP_ERR_TIMEOUT;
}
