/*
 * MQuickJS Erlang C Node - JavaScript Runtime
 *
 * This module manages the MQuickJS JavaScript engine:
 *   - Output buffer for capturing print() output
 *   - JavaScript builtin functions (print, Date.now, etc.)
 *   - Context initialization and lifecycle management
 *
 * The runtime maintains a single JS context that persists across calls,
 * allowing JavaScript state to be preserved between Erlang requests.
 *
 * Copyright Ericsson AB 2025. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0
 */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>

#include "mquickjs_cnode.h"
#include "cutils.h"

/*
 * ============================================================================
 * Output Buffer
 * ============================================================================
 *
 * The output buffer captures text from JavaScript's print() function.
 * It grows dynamically as needed and is cleared before each eval.
 *
 * Thread safety: Not thread-safe. Only one thread should access the buffer.
 */

/** Output buffer storage */
static char *g_output_buffer = NULL;

/** Allocated size of output buffer */
static size_t g_output_buffer_size = 0;

/** Current length of content in buffer */
static size_t g_output_buffer_len = 0;

void output_buffer_clear(void)
{
    g_output_buffer_len = 0;
    if (g_output_buffer) {
        g_output_buffer[0] = '\0';
    }
}

void output_buffer_append(const char *str, size_t len)
{
    size_t new_len = g_output_buffer_len + len;

    /* Grow buffer if needed */
    if (new_len + 1 > g_output_buffer_size) {
        size_t new_size = (new_len + 1) * 2;
        if (new_size < 4096) new_size = 4096;  /* Minimum 4KB */

        char *new_buf = realloc(g_output_buffer, new_size);
        if (!new_buf) {
            fprintf(stderr, "Warning: Failed to grow output buffer\n");
            return;
        }
        g_output_buffer = new_buf;
        g_output_buffer_size = new_size;
    }

    /* Append the text */
    memcpy(g_output_buffer + g_output_buffer_len, str, len);
    g_output_buffer_len = new_len;
    g_output_buffer[g_output_buffer_len] = '\0';
}

const char *output_buffer_get(size_t *len)
{
    if (len) {
        *len = g_output_buffer_len;
    }
    return g_output_buffer;
}

void output_buffer_free(void)
{
    if (g_output_buffer) {
        free(g_output_buffer);
        g_output_buffer = NULL;
        g_output_buffer_size = 0;
        g_output_buffer_len = 0;
    }
}

/*
 * ============================================================================
 * JavaScript Builtin Functions
 * ============================================================================
 *
 * These functions are exposed to JavaScript code running in the engine.
 * They bridge the gap between JS and the C node environment.
 */

/**
 * print(...args) - Output text to the capture buffer.
 *
 * Similar to console.log(), prints arguments separated by spaces,
 * followed by a newline. All output is captured in the output buffer
 * and can be retrieved via the get_output command.
 *
 * Example JS: print("Hello", "world", 42);
 * Output: "Hello world 42\n"
 */
static JSValue js_print(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    int i;
    JSValue v;

    for (i = 0; i < argc; i++) {
        /* Add space between arguments */
        if (i != 0) {
            output_buffer_append(" ", 1);
        }

        v = argv[i];
        if (JS_IsString(ctx, v)) {
            /* Fast path for strings - no conversion needed */
            JSCStringBuf buf;
            const char *str;
            size_t len;
            str = JS_ToCStringLen(ctx, &len, v, &buf);
            output_buffer_append(str, len);
        } else {
            /* Convert other types to string */
            JSValue str_val = JS_ToString(ctx, v);
            if (!JS_IsException(str_val)) {
                JSCStringBuf buf;
                const char *str;
                size_t len;
                str = JS_ToCStringLen(ctx, &len, str_val, &buf);
                output_buffer_append(str, len);
            }
        }
    }

    /* Add newline */
    output_buffer_append("\n", 1);
    return JS_UNDEFINED;
}

/**
 * Date.now() - Return current timestamp in milliseconds.
 *
 * Returns the number of milliseconds since Unix epoch (1970-01-01 00:00:00 UTC).
 * Used for timing and date calculations in JavaScript.
 */
static JSValue js_date_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return JS_NewInt64(ctx, (int64_t)tv.tv_sec * 1000 + (tv.tv_usec / 1000));
}

/**
 * performance.now() - Return high-resolution timestamp.
 *
 * Currently returns the same as Date.now() (millisecond precision).
 * In a full implementation, this would return sub-millisecond precision.
 */
static JSValue js_performance_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return JS_NewInt64(ctx, (int64_t)tv.tv_sec * 1000 + (tv.tv_usec / 1000));
}

/**
 * gc() - Trigger garbage collection.
 *
 * Forces an immediate garbage collection cycle. Useful for:
 *   - Reducing memory pressure before large allocations
 *   - Testing memory behavior
 *   - Clearing temporary objects
 */
static JSValue js_gc(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    JS_GC(ctx);
    return JS_UNDEFINED;
}

/*
 * Stub functions for unsupported features.
 *
 * These functions exist in the standard MQuickJS environment but are
 * not meaningful in the C node context. They throw errors to alert
 * JavaScript code that these features are unavailable.
 */

/** load() - Not supported (no filesystem access in C node) */
static JSValue js_load(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return JS_ThrowError(ctx, JS_CLASS_ERROR,
                         "load() is not supported in C node mode");
}

/** setTimeout() - Not supported (no event loop in C node) */
static JSValue js_setTimeout(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return JS_ThrowError(ctx, JS_CLASS_ERROR,
                         "setTimeout() is not supported in C node mode");
}

/** clearTimeout() - Not supported (no event loop in C node) */
static JSValue js_clearTimeout(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return JS_ThrowError(ctx, JS_CLASS_ERROR,
                         "clearTimeout() is not supported in C node mode");
}

/*
 * Include the MQuickJS standard library.
 *
 * This header defines js_stdlib which provides the standard JavaScript
 * objects and functions (Object, Array, String, Math, JSON, etc.).
 * Our custom builtin functions above are registered separately.
 */
#include "mqjs_stdlib.h"

/*
 * ============================================================================
 * JavaScript Context Management
 * ============================================================================
 *
 * The JS context is the execution environment for JavaScript code.
 * It includes:
 *   - Global object with builtins
 *   - Memory allocator with fixed-size buffer
 *   - Runtime state (variables, closures, etc.)
 *
 * Memory Model:
 *   MQuickJS uses a single contiguous memory buffer. All JavaScript
 *   allocations come from this buffer. If it fills up, allocations
 *   fail. The buffer size is fixed at context creation time.
 */

/** The JavaScript execution context */
static JSContext *g_js_ctx = NULL;

/** Memory buffer for JS allocations */
static uint8_t *g_mem_buf = NULL;

/** Size of memory buffer */
static size_t g_mem_size = DEFAULT_MEM_SIZE;

/**
 * Log function callback for MQuickJS.
 *
 * MQuickJS calls this for internal logging. We redirect it to our
 * output buffer so it can be captured along with print() output.
 */
static void js_log_func(void *opaque, const void *buf, size_t buf_len)
{
    (void)opaque;  /* Unused */
    output_buffer_append((const char *)buf, buf_len);
}

int js_runtime_init(size_t mem_size)
{
    /* Clean up existing context if any */
    if (g_js_ctx) {
        JS_FreeContext(g_js_ctx);
        free(g_mem_buf);
        g_js_ctx = NULL;
        g_mem_buf = NULL;
    }

    /* Use default if no size specified */
    g_mem_size = mem_size > 0 ? mem_size : DEFAULT_MEM_SIZE;

    /* Allocate memory buffer for JS engine */
    g_mem_buf = malloc(g_mem_size);
    if (!g_mem_buf) {
        fprintf(stderr, "Failed to allocate %zu bytes for JS context\n", g_mem_size);
        return -1;
    }

    /* Create the JavaScript context with standard library */
    g_js_ctx = JS_NewContext(g_mem_buf, g_mem_size, &js_stdlib);
    if (!g_js_ctx) {
        fprintf(stderr, "Failed to create JS context\n");
        free(g_mem_buf);
        g_mem_buf = NULL;
        return -1;
    }

    /* Set up logging to capture MQuickJS internal output */
    JS_SetLogFunc(g_js_ctx, js_log_func);

    /* Clear any stale output from previous context */
    output_buffer_clear();

    return 0;
}

void js_runtime_cleanup(void)
{
    if (g_js_ctx) {
        JS_FreeContext(g_js_ctx);
        g_js_ctx = NULL;
    }
    if (g_mem_buf) {
        free(g_mem_buf);
        g_mem_buf = NULL;
    }
    output_buffer_free();
}

JSContext *js_runtime_get_context(void)
{
    return g_js_ctx;
}

size_t js_runtime_get_mem_size(void)
{
    return g_mem_size;
}
