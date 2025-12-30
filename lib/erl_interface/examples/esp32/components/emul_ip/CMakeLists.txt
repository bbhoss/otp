idf_component_register(
    SRCS "emul_ip.c" "lwip_ethoc.c"
    INCLUDE_DIRS "."
    REQUIRES lwip esp_netif esp_event freertos
)

# Suppress warnings from older code
target_compile_options(${COMPONENT_LIB} PRIVATE
    -Wno-unused-variable
    -Wno-unused-function
    -Wno-implicit-function-declaration
)
