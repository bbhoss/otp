idf_component_register(
    SRCS
        "src/ei_connect.c"
        "src/ei_portio.c"
        "src/ei_resolve.c"
        "src/ei_malloc.c"
        "src/ei_locking.c"
        "src/ei_format.c"
        "src/ei_printterm.c"
        "src/ei_trace.c"
        "src/ei_decode_term.c"
        "src/get_type.c"
        "src/show_msg.c"
        "src/eirecv.c"
        "src/send.c"
        "src/send_reg.c"
        "src/send_exit.c"
        # md5_dgst.c removed - using mbedTLS instead
        "src/encode_atom.c"
        "src/encode_big.c"
        "src/encode_bignum.c"
        "src/encode_binary.c"
        "src/encode_boolean.c"
        "src/encode_char.c"
        "src/encode_double.c"
        "src/encode_fun.c"
        "src/encode_list_header.c"
        "src/encode_long.c"
        "src/encode_longlong.c"
        "src/encode_pid.c"
        "src/encode_port.c"
        "src/encode_ref.c"
        "src/encode_string.c"
        "src/encode_trace.c"
        "src/encode_tuple_header.c"
        "src/encode_ulong.c"
        "src/encode_ulonglong.c"
        "src/encode_version.c"
        "src/decode_atom.c"
        "src/decode_big.c"
        "src/decode_bignum.c"
        "src/decode_binary.c"
        "src/decode_boolean.c"
        "src/decode_char.c"
        "src/decode_double.c"
        "src/decode_fun.c"
        "src/decode_intlist.c"
        "src/decode_iodata.c"
        "src/decode_list_header.c"
        "src/decode_long.c"
        "src/decode_longlong.c"
        "src/decode_pid.c"
        "src/decode_port.c"
        "src/decode_ref.c"
        "src/decode_skip.c"
        "src/decode_string.c"
        "src/decode_trace.c"
        "src/decode_tuple_header.c"
        "src/decode_ulong.c"
        "src/decode_ulonglong.c"
        "src/decode_version.c"
        "src/ei_x_encode.c"
        "src/ei_esp32.c"
    INCLUDE_DIRS "include"
    REQUIRES lwip mbedtls esp_system
)

# ESP32 specific defines
target_compile_definitions(${COMPONENT_LIB} PRIVATE
    ESP_PLATFORM=1
    EI_NO_EPMD=1
)

# Suppress some warnings from erl_interface code
target_compile_options(${COMPONENT_LIB} PRIVATE
    -Wno-char-subscripts
    -Wno-implicit-function-declaration
)
