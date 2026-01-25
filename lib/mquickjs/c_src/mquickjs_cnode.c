/*
 * MQuickJS Erlang C Node
 *
 * A C node that embeds the MQuickJS JavaScript engine and provides
 * an interface for Erlang to evaluate JavaScript code.
 *
 * Copyright Ericsson AB 2025. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <stdarg.h>
#include <math.h>
#include <sys/time.h>

#ifndef _WIN32
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#endif

#include "ei.h"
#include "mquickjs.h"
#include "cutils.h"

/* Output capture buffer */
static char *g_output_buffer = NULL;
static size_t g_output_buffer_size = 0;
static size_t g_output_buffer_len = 0;

static void clear_output_buffer(void)
{
    g_output_buffer_len = 0;
    if (g_output_buffer) {
        g_output_buffer[0] = '\0';
    }
}

static void append_output(const char *str, size_t len)
{
    size_t new_len = g_output_buffer_len + len;
    if (new_len + 1 > g_output_buffer_size) {
        size_t new_size = (new_len + 1) * 2;
        if (new_size < 4096) new_size = 4096;
        char *new_buf = realloc(g_output_buffer, new_size);
        if (!new_buf) return;
        g_output_buffer = new_buf;
        g_output_buffer_size = new_size;
    }
    memcpy(g_output_buffer + g_output_buffer_len, str, len);
    g_output_buffer_len = new_len;
    g_output_buffer[g_output_buffer_len] = '\0';
}

/* JS print function - captures output */
static JSValue js_print(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    int i;
    JSValue v;

    for (i = 0; i < argc; i++) {
        if (i != 0) {
            append_output(" ", 1);
        }
        v = argv[i];
        if (JS_IsString(ctx, v)) {
            JSCStringBuf buf;
            const char *str;
            size_t len;
            str = JS_ToCStringLen(ctx, &len, v, &buf);
            append_output(str, len);
        } else {
            JSValue str_val = JS_ToString(ctx, v);
            if (!JS_IsException(str_val)) {
                JSCStringBuf buf;
                const char *str;
                size_t len;
                str = JS_ToCStringLen(ctx, &len, str_val, &buf);
                append_output(str, len);
            }
        }
    }
    append_output("\n", 1);
    return JS_UNDEFINED;
}

/* JS Date.now() */
static JSValue js_date_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return JS_NewInt64(ctx, (int64_t)tv.tv_sec * 1000 + (tv.tv_usec / 1000));
}

/* JS performance.now() */
static JSValue js_performance_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return JS_NewInt64(ctx, (int64_t)tv.tv_sec * 1000 + (tv.tv_usec / 1000));
}

/* JS gc() - trigger garbage collection */
static JSValue js_gc(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    JS_GC(ctx);
    return JS_UNDEFINED;
}

/* JS load() - stub, not supported in C node */
static JSValue js_load(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return JS_ThrowError(ctx, JS_CLASS_ERROR, "load() is not supported in C node mode");
}

/* JS setTimeout() - stub, not supported in C node */
static JSValue js_setTimeout(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return JS_ThrowError(ctx, JS_CLASS_ERROR, "setTimeout() is not supported in C node mode");
}

/* JS clearTimeout() - stub, not supported in C node */
static JSValue js_clearTimeout(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return JS_ThrowError(ctx, JS_CLASS_ERROR, "clearTimeout() is not supported in C node mode");
}

/* Include the generated stdlib (use mqjs_stdlib.h from mquickjs - without example classes) */
#include "mqjs_stdlib.h"

/* Default memory size for JS context (256KB) */
#define DEFAULT_MEM_SIZE (256 * 1024)

/* Maximum message size */
#define MAX_MSG_SIZE (64 * 1024)

/* Global state */
static JSContext *g_js_ctx = NULL;
static uint8_t *g_mem_buf = NULL;
static size_t g_mem_size = DEFAULT_MEM_SIZE;
static volatile int g_running = 1;

/* Log function for mquickjs */
static void js_log_func(void *opaque, const void *buf, size_t buf_len)
{
    (void)opaque;
    append_output((const char *)buf, buf_len);
}

/* Initialize the JavaScript context */
static int init_js_context(size_t mem_size)
{
    if (g_js_ctx) {
        JS_FreeContext(g_js_ctx);
        free(g_mem_buf);
    }

    g_mem_size = mem_size > 0 ? mem_size : DEFAULT_MEM_SIZE;
    g_mem_buf = malloc(g_mem_size);
    if (!g_mem_buf) {
        fprintf(stderr, "Failed to allocate memory for JS context\n");
        return -1;
    }

    g_js_ctx = JS_NewContext(g_mem_buf, g_mem_size, &js_stdlib);
    if (!g_js_ctx) {
        fprintf(stderr, "Failed to create JS context\n");
        free(g_mem_buf);
        g_mem_buf = NULL;
        return -1;
    }

    JS_SetLogFunc(g_js_ctx, js_log_func);
    clear_output_buffer();
    return 0;
}

/* Cleanup JavaScript context */
static void cleanup_js_context(void)
{
    if (g_js_ctx) {
        JS_FreeContext(g_js_ctx);
        g_js_ctx = NULL;
    }
    if (g_mem_buf) {
        free(g_mem_buf);
        g_mem_buf = NULL;
    }
    if (g_output_buffer) {
        free(g_output_buffer);
        g_output_buffer = NULL;
        g_output_buffer_size = 0;
        g_output_buffer_len = 0;
    }
}

/* Convert a JSValue to an Erlang term and encode it */
static int encode_jsvalue(ei_x_buff *x, JSContext *ctx, JSValue val)
{
    if (JS_IsException(val)) {
        JSValue exc = JS_GetException(ctx);
        JSCStringBuf buf;
        const char *str = JS_ToCString(ctx, exc, &buf);
        ei_x_encode_tuple_header(x, 2);
        ei_x_encode_atom(x, "error");
        if (str) {
            ei_x_encode_string(x, str);
        } else {
            ei_x_encode_string(x, "unknown error");
        }
        return 0;
    }

    if (JS_IsUndefined(val)) {
        ei_x_encode_atom(x, "undefined");
        return 0;
    }

    if (JS_IsNull(val)) {
        ei_x_encode_atom(x, "null");
        return 0;
    }

    if (JS_IsBool(val)) {
        int b = JS_VALUE_GET_SPECIAL_VALUE(val);
        ei_x_encode_atom(x, b ? "true" : "false");
        return 0;
    }

    if (JS_IsInt(val)) {
        int i = JS_VALUE_GET_INT(val);
        ei_x_encode_long(x, i);
        return 0;
    }

    if (JS_IsNumber(ctx, val)) {
        double d;
        if (JS_ToNumber(ctx, &d, val) == 0) {
            ei_x_encode_double(x, d);
        } else {
            ei_x_encode_atom(x, "nan");
        }
        return 0;
    }

    if (JS_IsString(ctx, val)) {
        JSCStringBuf buf;
        size_t len;
        const char *str = JS_ToCStringLen(ctx, &len, val, &buf);
        if (str) {
            ei_x_encode_binary(x, str, len);
        } else {
            ei_x_encode_binary(x, "", 0);
        }
        return 0;
    }

    /* For objects/arrays, convert to string representation */
    {
        JSValue str_val = JS_ToString(ctx, val);
        if (!JS_IsException(str_val)) {
            JSCStringBuf buf;
            size_t len;
            const char *str = JS_ToCStringLen(ctx, &len, str_val, &buf);
            if (str) {
                ei_x_encode_binary(x, str, len);
            } else {
                ei_x_encode_binary(x, "[object]", 8);
            }
        } else {
            ei_x_encode_binary(x, "[object]", 8);
        }
    }
    return 0;
}

/* Handle eval command */
static int handle_eval(ei_x_buff *resp, const char *buf, int *index)
{
    int type, size;
    char *code = NULL;
    long code_len;
    JSValue result;

    if (ei_get_type(buf, index, &type, &size) < 0) {
        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "error");
        ei_x_encode_string(resp, "failed to get type");
        return 0;
    }

    code = malloc(size + 1);
    if (!code) {
        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "error");
        ei_x_encode_string(resp, "out of memory");
        return 0;
    }

    if (type == ERL_BINARY_EXT) {
        if (ei_decode_binary(buf, index, code, &code_len) < 0) {
            free(code);
            ei_x_encode_tuple_header(resp, 2);
            ei_x_encode_atom(resp, "error");
            ei_x_encode_string(resp, "failed to decode binary");
            return 0;
        }
        code[code_len] = '\0';
    } else {
        if (ei_decode_string(buf, index, code) < 0) {
            free(code);
            ei_x_encode_tuple_header(resp, 2);
            ei_x_encode_atom(resp, "error");
            ei_x_encode_string(resp, "failed to decode string");
            return 0;
        }
        code_len = strlen(code);
    }

    /* Clear output buffer before eval */
    clear_output_buffer();

    /* Evaluate the code */
    result = JS_Eval(g_js_ctx, code, code_len, "<eval>", JS_EVAL_RETVAL);
    free(code);

    /* Encode the result */
    if (JS_IsException(result)) {
        JSValue exc = JS_GetException(g_js_ctx);
        JSCStringBuf buf;
        const char *str = JS_ToCString(g_js_ctx, exc, &buf);

        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "error");
        if (str) {
            ei_x_encode_string(resp, str);
        } else {
            ei_x_encode_string(resp, "unknown error");
        }
    } else {
        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "ok");
        encode_jsvalue(resp, g_js_ctx, result);
    }

    return 0;
}

/* Handle get_output command */
static int handle_get_output(ei_x_buff *resp)
{
    ei_x_encode_tuple_header(resp, 2);
    ei_x_encode_atom(resp, "ok");
    ei_x_encode_binary(resp, g_output_buffer ? g_output_buffer : "", g_output_buffer_len);
    return 0;
}

/* Handle gc command */
static int handle_gc(ei_x_buff *resp)
{
    JS_GC(g_js_ctx);
    ei_x_encode_atom(resp, "ok");
    return 0;
}

/* Handle reset command */
static int handle_reset(ei_x_buff *resp, const char *buf, int *index)
{
    long mem_size = DEFAULT_MEM_SIZE;
    int arity;

    if (ei_decode_tuple_header(buf, index, &arity) == 0 && arity == 1) {
        ei_decode_long(buf, index, &mem_size);
    }

    if (init_js_context((size_t)mem_size) < 0) {
        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "error");
        ei_x_encode_string(resp, "failed to reset context");
    } else {
        ei_x_encode_atom(resp, "ok");
    }

    return 0;
}

/* Handle stop command */
static int handle_stop(ei_x_buff *resp)
{
    ei_x_encode_atom(resp, "ok");
    g_running = 0;
    return 0;
}

/* Process a message from Erlang */
static int process_message(int fd, erlang_pid *from, ei_x_buff *buf)
{
    ei_x_buff resp;
    int index = 0;
    int version;
    int arity;
    char cmd[MAXATOMLEN];

    ei_x_new_with_version(&resp);

    if (ei_decode_version(buf->buff, &index, &version) < 0) {
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "error");
        ei_x_encode_string(&resp, "no version");
        goto send_response;
    }

    if (ei_decode_tuple_header(buf->buff, &index, &arity) < 0) {
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "error");
        ei_x_encode_string(&resp, "expected tuple");
        goto send_response;
    }

    if (ei_decode_atom(buf->buff, &index, cmd) < 0) {
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "error");
        ei_x_encode_string(&resp, "expected atom command");
        goto send_response;
    }

    if (strcmp(cmd, "eval") == 0 && arity == 2) {
        handle_eval(&resp, buf->buff, &index);
    } else if (strcmp(cmd, "get_output") == 0 && arity == 1) {
        handle_get_output(&resp);
    } else if (strcmp(cmd, "gc") == 0 && arity == 1) {
        handle_gc(&resp);
    } else if (strcmp(cmd, "reset") == 0) {
        handle_reset(&resp, buf->buff, &index);
    } else if (strcmp(cmd, "stop") == 0 && arity == 1) {
        handle_stop(&resp);
    } else {
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "error");
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "unknown_command");
        ei_x_encode_atom(&resp, cmd);
    }

send_response:
    ei_send(fd, from, resp.buff, resp.index);
    ei_x_free(&resp);
    return 0;
}

static void signal_handler(int sig)
{
    (void)sig;
    g_running = 0;
}

static void usage(const char *progname)
{
    fprintf(stderr, "Usage: %s [-n nodename] [-c cookie] [-e erlang_node] [-m memsize]\n", progname);
    fprintf(stderr, "  -n nodename    : Name of this C node (default: mquickjs)\n");
    fprintf(stderr, "  -c cookie      : Erlang cookie\n");
    fprintf(stderr, "  -e erlang_node : Erlang node to connect to\n");
    fprintf(stderr, "  -m memsize     : JS memory size in KB (default: 256)\n");
    fprintf(stderr, "  -h             : Show this help\n");
}

int main(int argc, char *argv[])
{
    int fd = -1;
    int opt;
    const char *nodename = "mquickjs";
    const char *cookie = NULL;
    const char *erlang_node = NULL;
    size_t mem_size = DEFAULT_MEM_SIZE;
    ei_cnode ec;
    erlang_msg msg;
    ei_x_buff buf;
    int got;

    while ((opt = getopt(argc, argv, "n:c:e:m:h")) != -1) {
        switch (opt) {
        case 'n':
            nodename = optarg;
            break;
        case 'c':
            cookie = optarg;
            break;
        case 'e':
            erlang_node = optarg;
            break;
        case 'm':
            mem_size = (size_t)atol(optarg) * 1024;
            break;
        case 'h':
        default:
            usage(argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    if (!cookie) {
        fprintf(stderr, "Error: cookie is required (-c)\n");
        usage(argv[0]);
        return 1;
    }

    if (!erlang_node) {
        fprintf(stderr, "Error: erlang node is required (-e)\n");
        usage(argv[0]);
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN);
#endif

    if (ei_init() < 0) {
        fprintf(stderr, "Failed to initialize ei\n");
        return 1;
    }

    if (ei_connect_init(&ec, nodename, cookie, 0) < 0) {
        fprintf(stderr, "Failed to initialize C node: %s\n", strerror(erl_errno));
        return 1;
    }

    fprintf(stderr, "C node '%s' initialized\n", ei_thisnodename(&ec));

    fd = ei_connect(&ec, (char *)erlang_node);
    if (fd < 0) {
        fprintf(stderr, "Failed to connect to Erlang node '%s': %s\n",
                erlang_node, strerror(erl_errno));
        return 1;
    }

    fprintf(stderr, "Connected to Erlang node '%s'\n", erlang_node);

    if (init_js_context(mem_size) < 0) {
        fprintf(stderr, "Failed to initialize JavaScript context\n");
        ei_close_connection(fd);
        return 1;
    }

    fprintf(stderr, "JavaScript context initialized (mem_size=%zu)\n", g_mem_size);

    ei_x_new(&buf);

    while (g_running) {
        got = ei_xreceive_msg(fd, &msg, &buf);

        if (got == ERL_TICK) {
            continue;
        }

        if (got == ERL_ERROR) {
            if (erl_errno == EAGAIN || erl_errno == EINTR) {
                continue;
            }
            fprintf(stderr, "Receive error: %s\n", strerror(erl_errno));
            break;
        }

        if (msg.msgtype == ERL_SEND || msg.msgtype == ERL_REG_SEND) {
            process_message(fd, &msg.from, &buf);
        }
    }

    ei_x_free(&buf);
    cleanup_js_context();
    if (fd >= 0) {
        ei_close_connection(fd);
    }

    fprintf(stderr, "C node shutting down\n");
    return 0;
}
