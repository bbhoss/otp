/*
 * ESP32-specific implementations for erl_interface
 */

#ifdef ESP_PLATFORM

#include <string.h>
#include "ei.h"

/* Global erl_errno for non-reentrant builds */
volatile int __erl_errno = 0;

/* Provide gethostname for ESP32 */
int gethostname(char *name, size_t len)
{
    /* Return a fixed hostname for ESP32 */
    const char *hostname = "esp32host";
    size_t hostname_len = strlen(hostname);

    if (len < hostname_len + 1) {
        return -1;
    }

    strcpy(name, hostname);
    return 0;
}

#endif /* ESP_PLATFORM */
