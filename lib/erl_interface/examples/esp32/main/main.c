/*
 * ESP32 Erlang C Node - Connects to BEAM node
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "nvs_flash.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "emul_ip.h"
#include "ei.h"

static const char *TAG = "erlang_node";

/* Configuration for QEMU - host Erlang node */
#define ERLANG_HOST "10.0.2.2"
#define ERLANG_PORT 9000
#define ERLANG_COOKIE "testcookie"
#define ERLANG_NODE_NAME "erlnode@localhost"

/* Test Erlang term encoding */
static void test_ei_encoding(void)
{
    ei_x_buff x;
    ESP_LOGI(TAG, "Testing ei encoding...");

    if (ei_x_new_with_version(&x) < 0) {
        ESP_LOGE(TAG, "Failed to create ei_x_buff");
        return;
    }

    ei_x_encode_tuple_header(&x, 3);
    ei_x_encode_atom(&x, "hello");
    ei_x_encode_string(&x, "world");
    ei_x_encode_long(&x, 42);

    ESP_LOGI(TAG, "Encoded %d bytes: {hello, \"world\", 42}", x.index);
    ESP_LOG_BUFFER_HEX(TAG, x.buff, x.index);

    ei_x_free(&x);
    ESP_LOGI(TAG, "Encoding test complete!");
}

/* Connect to Erlang node and send a message */
static void test_erlang_connection(void)
{
    ei_cnode ec;
    int fd;

    ESP_LOGI(TAG, "=== ERLANG DISTRIBUTION TEST ===");
    ESP_LOGI(TAG, "Initializing C node 'esp32'...");

    /* Initialize the C node */
    if (ei_connect_xinit(&ec,
                         "esp32host",       /* hostname */
                         "esp32",           /* alivename */
                         "esp32@esp32host", /* full node name */
                         NULL,              /* IP */
                         ERLANG_COOKIE,     /* cookie must match! */
                         0) < 0) {
        ESP_LOGE(TAG, "ei_connect_xinit failed: erl_errno=%d", erl_errno);
        return;
    }

    ESP_LOGI(TAG, "C node: %s", ei_thisnodename(&ec));
    ESP_LOGI(TAG, "Connecting to %s:%d...", ERLANG_HOST, ERLANG_PORT);

    /* Connect directly to known host:port (bypassing EPMD) */
    fd = ei_connect_host_port(&ec, (char *)ERLANG_HOST, ERLANG_PORT);
    if (fd < 0) {
        ESP_LOGE(TAG, "ei_connect_host_port failed: erl_errno=%d", erl_errno);
        ESP_LOGE(TAG, "Make sure Erlang node is running on host port %d", ERLANG_PORT);
        return;
    }

    ESP_LOGI(TAG, "*** CONNECTED to Erlang node! fd=%d ***", fd);

    /* Encode and send a message: {hello_from_esp32, self()} */
    ei_x_buff x;
    ei_x_new_with_version(&x);
    ei_x_encode_tuple_header(&x, 2);
    ei_x_encode_atom(&x, "hello_from_esp32");
    ei_x_encode_pid(&x, ei_self(&ec));

    ESP_LOGI(TAG, "Sending {hello_from_esp32, <pid>} to 'esp_handler'...");

    if (ei_reg_send(&ec, fd, "esp_handler", x.buff, x.index) < 0) {
        ESP_LOGE(TAG, "ei_reg_send failed: erl_errno=%d", erl_errno);
    } else {
        ESP_LOGI(TAG, "*** MESSAGE SENT TO ERLANG! ***");
    }

    ei_x_free(&x);

    /* Keep connection open briefly */
    vTaskDelay(pdMS_TO_TICKS(2000));

    close(fd);
    ESP_LOGI(TAG, "Connection closed");
}

void app_main(void)
{
    ESP_LOGI(TAG, "ESP32 Erlang C Node starting...");
    ESP_LOGI(TAG, "Free heap: %lu bytes", esp_get_free_heap_size());

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    /* Test encoding */
    test_ei_encoding();

    /* Initialize network */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    ESP_LOGI(TAG, "Checking for QEMU environment...");
    ret = qemu_eth_init();

    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "QEMU network ready!");
        vTaskDelay(pdMS_TO_TICKS(1000));

        /* Try to connect to Erlang node */
        test_erlang_connection();
    } else {
        ESP_LOGW(TAG, "Not in QEMU - network unavailable");
    }

    ESP_LOGI(TAG, "Test complete. Free heap: %lu bytes", esp_get_free_heap_size());

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(10000));
    }
}
