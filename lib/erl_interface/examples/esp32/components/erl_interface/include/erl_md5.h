/*
 * MD5 wrapper for erl_interface
 * On ESP32, uses mbedTLS; otherwise uses embedded OpenSSL implementation.
 */

#ifndef ERL_MD5_H__
#define ERL_MD5_H__

#if defined(ESP_PLATFORM)

/* Use mbedTLS on ESP32 */
#include "mbedtls/md5.h"

typedef mbedtls_md5_context MD5_CTX;

static inline void ei_MD5Init(MD5_CTX *ctx) {
    mbedtls_md5_init(ctx);
    mbedtls_md5_starts(ctx);
}

static inline void ei_MD5Update(MD5_CTX *ctx, const unsigned char *data, unsigned long len) {
    mbedtls_md5_update(ctx, data, len);
}

static inline void ei_MD5Final(unsigned char *digest, MD5_CTX *ctx) {
    mbedtls_md5_finish(ctx, digest);
    mbedtls_md5_free(ctx);
}

#else /* not ESP_PLATFORM */

#undef ERLANG_OPENSSL_INTEGRATION
#define ERLANG_OPENSSL_INTEGRATION

#define MD5_INIT_FUNCTION_NAME                  ei_MD5Init
#define MD5_UPDATE_FUNCTION_NAME                ei_MD5Update
#define MD5_FINAL_FUNCTION_NAME                 ei_MD5Final
#define MD5_TRANSFORM_FUNCTION_NAME             ei_MD5Transform
#define MD5_BLOCK_DATA_ORDER_FUNCTION_NAME      ei_MD5BlockDataOrder

#include "openssl_local/md5.h"

#endif /* ESP_PLATFORM */

#endif /* ERL_MD5_H__ */
