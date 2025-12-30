/*
 * ESP32-specific configuration for erl_interface
 * Generated for ESP-IDF / Xtensa LX6 (32-bit)
 */

#ifndef EI_ESP32_CONFIG_H
#define EI_ESP32_CONFIG_H

/* ESP-IDF marker */
#define ESP_PLATFORM 1

/* Disable EPMD - we use direct connections */
#define EI_NO_EPMD 1

/* No cookie file - pass cookie programmatically */
#define EI_NO_COOKIE_FILE 1

/* Single threaded - no pthreads on ESP32 bare metal */
#undef _REENTRANT
#undef HAVE_PTHREAD_H
#undef HAVE_MIT_PTHREAD_H

/* Standard C functions available via newlib */
#define HAVE_ALLOCA 1
#define HAVE_ALLOCA_H 1
#define HAVE_MEMCHR 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMSET 1
#define HAVE_STRCHR 1
#define HAVE_STRRCHR 1
#define HAVE_STRSTR 1
#define HAVE_STRERROR 1

/* Standard headers */
#define HAVE_STDINT_H 1
#define HAVE_STDDEF_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_LIMITS_H 1
#define HAVE_INTTYPES_H 1
#define STDC_HEADERS 1

/* ESP-IDF lwIP provides BSD sockets */
#define HAVE_SOCKET 1
#define HAVE_SELECT 1
#define HAVE_SOCKLEN_T 1
#define HAVE_ARPA_INET_H 1
#define HAVE_NETDB_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_INET_NTOA 1

/* We have gethostbyname via lwIP */
#define HAVE_GETHOSTBYNAME 1
#define HAVE_GETHOSTBYADDR 1
/* But not the _r versions */
#undef HAVE_GETHOSTBYNAME_R
#undef HAVE_GETHOSTBYADDR_R

/* lwIP doesn't have writev by default */
#undef HAVE_WRITEV
#undef HAVE_SYS_UIO_H

/* No uname on ESP32 */
#undef HAVE_UNAME
#undef HAVE_SYS_WAIT_H

/* We do have gettimeofday via ESP-IDF */
#define HAVE_GETTIMEOFDAY 1
#define HAVE_SYS_TIME_H 1

/* ESP-IDF has fcntl */
#define HAVE_FCNTL_H 1

/* ESP-IDF has unistd.h (partial) */
#define HAVE_UNISTD_H 1

/* No gethostname - we'll set hostname explicitly */
#undef HAVE_GETHOSTNAME

/* ESP32 data types - 32-bit Xtensa */
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 4
#define SIZEOF_LONG_LONG 8
#define SIZEOF_VOID_P 4

/* No 128-bit integers on 32-bit ESP32 */
#undef SIZEOF___INT128_T

/* ESP32 supports unaligned access (with penalty) */
#define HAVE_UNALIGNED_WORD_ACCESS 1

/* No GMP library */
#undef HAVE_GMP_H
#undef HAVE_LIBGMP

/* No librt or libresolv */
#undef HAVE_LIBRT
#undef HAVE_LIBRESOLV

/* GCC atomics - ESP32 GCC supports these */
#define ETHR_HAVE_GCC___ATOMIC_BUILTINS 1
#define ETHR_HAVE___atomic_load_n 0xC        /* 4 and 8 byte */
#define ETHR_HAVE___atomic_store_n 0xC
#define ETHR_HAVE___atomic_compare_exchange_n 0xC
#define ETHR_HAVE___atomic_add_fetch 0xC
#define ETHR_HAVE___atomic_fetch_and 0xC
#define ETHR_HAVE___atomic_fetch_or 0xC

/* Package info */
#define PACKAGE_NAME "erl_interface"
#define PACKAGE_VERSION "5.5"
#define PACKAGE_STRING "erl_interface 5.5"

#endif /* EI_ESP32_CONFIG_H */
