/*
 * MQuickJS Erlang C Node - Erlang Protocol Handler
 *
 * This module handles communication with the Erlang VM:
 *   - Decoding incoming Erlang terms
 *   - Dispatching commands to appropriate handlers
 *   - Encoding JavaScript values as Erlang terms
 *   - Sending responses back to Erlang processes
 *
 * Message Format:
 *   Commands are tuples: {atom(), ...args}
 *   Responses are: {ok, Result} | {error, Reason} | ok
 *
 * Copyright Ericsson AB 2025. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0
 */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "mquickjs_cnode.h"

/*
 * ============================================================================
 * Global State
 * ============================================================================
 */

/** Running flag - set to 0 to stop the main loop */
volatile int g_running = 1;

/*
 * ============================================================================
 * JavaScript to Erlang Type Conversion
 * ============================================================================
 *
 * This function converts JavaScript values to Erlang terms using the
 * External Term Format. The conversion is lossy for complex types
 * (objects become string representations).
 *
 * Conversion Table:
 *   JS Type        -> Erlang Type
 *   ─────────────────────────────────
 *   undefined      -> atom 'undefined'
 *   null           -> atom 'null'
 *   boolean        -> atom 'true' | 'false'
 *   integer        -> integer
 *   number (float) -> float
 *   string         -> binary
 *   object         -> binary (string representation)
 *   array          -> binary (string representation)
 *   exception      -> {error, message}
 */

int encode_jsvalue(ei_x_buff *x, JSContext *ctx, JSValue val)
{
    /*
     * Check for JavaScript exception first.
     * Exceptions are converted to {error, message} tuples.
     */
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

    /*
     * Handle undefined - common return value for statements
     */
    if (JS_IsUndefined(val)) {
        ei_x_encode_atom(x, "undefined");
        return 0;
    }

    /*
     * Handle null
     */
    if (JS_IsNull(val)) {
        ei_x_encode_atom(x, "null");
        return 0;
    }

    /*
     * Handle booleans - convert to atoms 'true' or 'false'
     */
    if (JS_IsBool(val)) {
        int b = JS_VALUE_GET_SPECIAL_VALUE(val);
        ei_x_encode_atom(x, b ? "true" : "false");
        return 0;
    }

    /*
     * Handle integers - MQuickJS distinguishes int from float
     */
    if (JS_IsInt(val)) {
        int i = JS_VALUE_GET_INT(val);
        ei_x_encode_long(x, i);
        return 0;
    }

    /*
     * Handle floating-point numbers
     */
    if (JS_IsNumber(ctx, val)) {
        double d;
        if (JS_ToNumber(ctx, &d, val) == 0) {
            ei_x_encode_double(x, d);
        } else {
            ei_x_encode_atom(x, "nan");
        }
        return 0;
    }

    /*
     * Handle strings - convert to Erlang binary
     * Binary is preferred over string for UTF-8 compatibility
     */
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

    /*
     * Handle objects and arrays - convert to string representation.
     *
     * For objects, this calls toString() which may return "[object Object]"
     * or a custom string if the object has a toString method.
     *
     * For better interoperability, consider using JSON.stringify() in
     * JavaScript before returning complex objects.
     */
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

/*
 * ============================================================================
 * Command Handlers
 * ============================================================================
 *
 * Each handler function processes a specific command type.
 * They follow a common pattern:
 *   1. Decode command-specific arguments from the message buffer
 *   2. Perform the requested operation
 *   3. Encode the response into the response buffer
 */

/**
 * Handle 'eval' command - Evaluate JavaScript code.
 *
 * Message format: {eval, Code}
 *   Code can be a string or binary containing JavaScript source.
 *
 * Response format: {ok, Result} | {error, Reason}
 *   Result is the value of the last expression in the code.
 *   For statements (if, for, etc.), Result is 'undefined'.
 *
 * Example:
 *   Input:  {eval, "1 + 2"}
 *   Output: {ok, 3}
 *
 *   Input:  {eval, "var x = 10; x * 2"}
 *   Output: {ok, 20}
 */
int handle_eval(ei_x_buff *resp, const char *buf, int *index)
{
    int type, size;
    char *code = NULL;
    long code_len;
    JSValue result;
    JSContext *ctx = js_runtime_get_context();

    /* Get the type and size of the code argument */
    if (ei_get_type(buf, index, &type, &size) < 0) {
        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "error");
        ei_x_encode_string(resp, "failed to get type");
        return 0;
    }

    /* Allocate buffer for code (with null terminator) */
    code = malloc(size + 1);
    if (!code) {
        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "error");
        ei_x_encode_string(resp, "out of memory");
        return 0;
    }

    /* Decode the code - handle both binary and string formats */
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
        /* Assume string format */
        if (ei_decode_string(buf, index, code) < 0) {
            free(code);
            ei_x_encode_tuple_header(resp, 2);
            ei_x_encode_atom(resp, "error");
            ei_x_encode_string(resp, "failed to decode string");
            return 0;
        }
        code_len = strlen(code);
    }

    /* Clear output buffer before evaluation */
    output_buffer_clear();

    /* Evaluate the JavaScript code */
    result = JS_Eval(ctx, code, code_len, "<eval>", JS_EVAL_RETVAL);
    free(code);

    /* Encode the result */
    if (JS_IsException(result)) {
        /* Get exception details */
        JSValue exc = JS_GetException(ctx);
        JSCStringBuf ebuf;
        const char *str = JS_ToCString(ctx, exc, &ebuf);

        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "error");
        if (str) {
            ei_x_encode_string(resp, str);
        } else {
            ei_x_encode_string(resp, "unknown error");
        }
    } else {
        /* Success - encode the return value */
        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "ok");
        encode_jsvalue(resp, ctx, result);
    }

    return 0;
}

/**
 * Handle 'get_output' command - Retrieve captured console output.
 *
 * Message format: {get_output}
 *
 * Response format: {ok, Output}
 *   Output is a binary containing all text from print() calls
 *   since the last eval command.
 *
 * Example:
 *   After: eval("print('hello'); print('world');")
 *   Input:  {get_output}
 *   Output: {ok, <<"hello\nworld\n">>}
 */
int handle_get_output(ei_x_buff *resp)
{
    size_t len;
    const char *output = output_buffer_get(&len);

    ei_x_encode_tuple_header(resp, 2);
    ei_x_encode_atom(resp, "ok");
    ei_x_encode_binary(resp, output ? output : "", len);

    return 0;
}

/**
 * Handle 'gc' command - Trigger garbage collection.
 *
 * Message format: {gc}
 *
 * Response format: ok
 *
 * Forces an immediate garbage collection cycle in the JavaScript engine.
 * This can help free up memory after processing large data structures.
 */
int handle_gc(ei_x_buff *resp)
{
    JSContext *ctx = js_runtime_get_context();
    JS_GC(ctx);
    ei_x_encode_atom(resp, "ok");
    return 0;
}

/**
 * Handle 'reset' command - Reset JavaScript context.
 *
 * Message format: {reset} | {reset, MemSize}
 *   MemSize is the memory buffer size in bytes (optional).
 *
 * Response format: ok | {error, Reason}
 *
 * Creates a fresh JavaScript context, clearing all variables and state.
 * Useful for:
 *   - Starting fresh after errors
 *   - Changing memory allocation size
 *   - Cleaning up after long-running sessions
 */
int handle_reset(ei_x_buff *resp, const char *buf, int *index)
{
    long mem_size = DEFAULT_MEM_SIZE;
    int arity;

    /* Check for optional memory size argument */
    if (ei_decode_tuple_header(buf, index, &arity) == 0 && arity == 1) {
        ei_decode_long(buf, index, &mem_size);
    }

    /* Initialize fresh context */
    if (js_runtime_init((size_t)mem_size) < 0) {
        ei_x_encode_tuple_header(resp, 2);
        ei_x_encode_atom(resp, "error");
        ei_x_encode_string(resp, "failed to reset context");
    } else {
        ei_x_encode_atom(resp, "ok");
    }

    return 0;
}

/**
 * Handle 'stop' command - Shutdown the C node.
 *
 * Message format: {stop}
 *
 * Response format: ok
 *
 * Signals the main loop to exit, causing a graceful shutdown.
 * The response is sent before shutdown begins.
 */
int handle_stop(ei_x_buff *resp)
{
    ei_x_encode_atom(resp, "ok");
    g_running = 0;  /* Signal main loop to exit */
    return 0;
}

/*
 * ============================================================================
 * Message Processing
 * ============================================================================
 *
 * This is the main dispatcher that routes incoming messages to handlers.
 */

/**
 * Process an incoming message from Erlang.
 *
 * Message structure:
 *   Version byte + {Command, ...Args}
 *
 * The function:
 *   1. Decodes the version byte
 *   2. Decodes the tuple header
 *   3. Extracts the command atom
 *   4. Dispatches to the appropriate handler
 *   5. Sends the response back to the sender
 */
int process_message(int fd, erlang_pid *from, ei_x_buff *buf)
{
    ei_x_buff resp;
    int index = 0;
    int version;
    int arity;
    char cmd[MAXATOMLEN];

    /* Initialize response buffer with version byte */
    ei_x_new_with_version(&resp);

    /* Decode version byte (required for all external terms) */
    if (ei_decode_version(buf->buff, &index, &version) < 0) {
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "error");
        ei_x_encode_string(&resp, "no version");
        goto send_response;
    }

    /* Decode tuple header - all commands are tuples */
    if (ei_decode_tuple_header(buf->buff, &index, &arity) < 0) {
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "error");
        ei_x_encode_string(&resp, "expected tuple");
        goto send_response;
    }

    /* Decode command atom - first element of tuple */
    if (ei_decode_atom(buf->buff, &index, cmd) < 0) {
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "error");
        ei_x_encode_string(&resp, "expected atom command");
        goto send_response;
    }

    /*
     * Dispatch to appropriate handler based on command.
     * Each handler encodes its response into 'resp'.
     */
    if (strcmp(cmd, "eval") == 0 && arity == 2) {
        handle_eval(&resp, buf->buff, &index);
    }
    else if (strcmp(cmd, "get_output") == 0 && arity == 1) {
        handle_get_output(&resp);
    }
    else if (strcmp(cmd, "gc") == 0 && arity == 1) {
        handle_gc(&resp);
    }
    else if (strcmp(cmd, "reset") == 0) {
        handle_reset(&resp, buf->buff, &index);
    }
    else if (strcmp(cmd, "stop") == 0 && arity == 1) {
        handle_stop(&resp);
    }
    else {
        /* Unknown command - return error with command name */
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "error");
        ei_x_encode_tuple_header(&resp, 2);
        ei_x_encode_atom(&resp, "unknown_command");
        ei_x_encode_atom(&resp, cmd);
    }

send_response:
    /* Send response back to the Erlang process */
    ei_send(fd, from, resp.buff, resp.index);
    ei_x_free(&resp);

    return 0;
}
