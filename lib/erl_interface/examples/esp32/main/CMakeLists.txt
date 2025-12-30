idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    REQUIRES erl_interface nvs_flash esp_netif esp_event emul_ip
)
