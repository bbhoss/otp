/*
 * MQuickJS Erlang C Node - Header
 *
 * This header defines the interface for the MQuickJS C node, which embeds
 * the MQuickJS JavaScript engine and provides an Erlang-compatible interface
 * via the erl_interface (ei) library.
 *
 * Architecture Overview:
 * =====================
 *
 *  ┌─────────────────┐           ┌─────────────────────────────────┐
 *  │   Erlang VM     │           │         C Node Process          │
 *  │                 │           │                                 │
 *  │  ┌───────────┐  │  ei_send  │  ┌─────────────────────────┐   │
 *  │  │ mquickjs  │──┼───────────┼─>│   erlang_protocol.c     │   │
 *  │  │ gen_server│  │           │  │   - Message parsing     │   │
 *  │  └───────────┘  │           │  │   - Command dispatch    │   │
 *  │                 │           │  │   - Response encoding   │   │
 *  │                 │  ei_recv  │  └───────────┬─────────────┘   │
 *  │                 │<──────────┼──────────────┘                 │
 *  │                 │           │               │                │
 *  │                 │           │  ┌────────────▼────────────┐   │
 *  │                 │           │  │     js_runtime.c        │   │
 *  │                 │           │  │   - JS context mgmt     │   │
 *  │                 │           │  │   - Builtin functions   │   │
 *  │                 │           │  │   - Output capture      │   │
 *  │                 │           │  └────────────┬────────────┘   │
 *  │                 │           │               │                │
 *  │                 │           │  ┌────────────▼────────────┐   │
 *  │                 │           │  │      MQuickJS Engine    │   │
 *  │                 │           │  │   (ES5 JavaScript)      │   │
 *  │                 │           │  └─────────────────────────┘   │
 *  └─────────────────┘           └─────────────────────────────────┘
 *
 * Message Protocol:
 * ================
 *
 * All messages are Erlang terms encoded with the External Term Format.
 * The C node receives commands as tuples and sends responses back.
 *
 * Commands (Erlang -> C Node):
 *   {eval, Code}        - Evaluate JavaScript code, return result
 *   {get_output}        - Get captured console output (from print())
 *   {gc}                - Trigger JavaScript garbage collection
 *   {reset, MemSize}    - Reset JS context with new memory size
 *   {stop}              - Shutdown the C node
 *
 * Responses (C Node -> Erlang):
 *   {ok, Result}        - Success with result value
 *   {error, Reason}     - Error with description
 *   ok                  - Simple success (gc, stop)
 *
 * Type Mapping (JavaScript -> Erlang):
 * ===================================
 *   undefined     -> atom 'undefined'
 *   null          -> atom 'null'
 *   boolean       -> atom 'true' | 'false'
 *   integer       -> integer
 *   number        -> float
 *   string        -> binary
 *   object/array  -> binary (JSON string representation)
 *
 * Copyright Ericsson AB 2025. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

#ifndef MQUICKJS_CNODE_H
#define MQUICKJS_CNODE_H

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "ei.h"
#include "mquickjs.h"

/*
 * ============================================================================
 * Configuration Constants
 * ============================================================================
 */

/** Default memory size for JS context (256KB) */
#define DEFAULT_MEM_SIZE (256 * 1024)

/** Maximum message size for Erlang communication */
#define MAX_MSG_SIZE (64 * 1024)

/*
 * ============================================================================
 * Output Buffer Management (js_runtime.c)
 * ============================================================================
 *
 * The output buffer captures text written by JavaScript's print() function.
 * This allows Erlang to retrieve console output after evaluating code.
 *
 * Usage pattern:
 *   1. Erlang calls eval("print('hello'); ...")
 *   2. JS print() appends to output buffer
 *   3. Erlang calls get_output to retrieve captured text
 *   4. Buffer is cleared on next eval
 */

/**
 * Clear the output buffer.
 * Called automatically before each eval command.
 */
void output_buffer_clear(void);

/**
 * Append text to the output buffer.
 * Called by the JS print() builtin function.
 *
 * @param str  Text to append
 * @param len  Length of text in bytes
 */
void output_buffer_append(const char *str, size_t len);

/**
 * Get current output buffer contents.
 *
 * @param len  Output parameter for buffer length
 * @return     Pointer to buffer contents (may be NULL if empty)
 */
const char *output_buffer_get(size_t *len);

/**
 * Free output buffer resources.
 * Called during cleanup.
 */
void output_buffer_free(void);

/*
 * ============================================================================
 * JavaScript Runtime Management (js_runtime.c)
 * ============================================================================
 *
 * The JS runtime manages a single MQuickJS context that persists across
 * multiple eval calls. This allows JavaScript state (variables, closures,
 * objects) to be maintained between Erlang requests.
 *
 * Memory Model:
 *   MQuickJS uses a fixed-size memory buffer allocated at context creation.
 *   If the buffer fills up, allocations fail and errors are returned.
 *   Use the 'reset' command to create a new context with different size.
 */

/**
 * Initialize the JavaScript context.
 *
 * @param mem_size  Memory buffer size in bytes (0 for default)
 * @return          0 on success, -1 on failure
 */
int js_runtime_init(size_t mem_size);

/**
 * Cleanup JavaScript context and free resources.
 */
void js_runtime_cleanup(void);

/**
 * Get the current JavaScript context.
 *
 * @return  Pointer to JSContext, or NULL if not initialized
 */
JSContext *js_runtime_get_context(void);

/**
 * Get the current memory size.
 *
 * @return  Memory buffer size in bytes
 */
size_t js_runtime_get_mem_size(void);

/*
 * ============================================================================
 * Erlang Protocol Handling (erlang_protocol.c)
 * ============================================================================
 *
 * These functions handle the Erlang communication protocol:
 *   - Decoding incoming command tuples
 *   - Dispatching to appropriate handlers
 *   - Encoding JavaScript values as Erlang terms
 *   - Sending responses back to Erlang
 */

/**
 * Encode a JavaScript value as an Erlang term.
 *
 * Conversion rules:
 *   - undefined, null -> atoms
 *   - boolean -> atom 'true' or 'false'
 *   - integer -> Erlang integer
 *   - number -> Erlang float
 *   - string -> Erlang binary
 *   - object/array -> binary (string representation)
 *   - exception -> {error, message}
 *
 * @param x    Erlang term buffer to encode into
 * @param ctx  JavaScript context
 * @param val  JavaScript value to encode
 * @return     0 on success
 */
int encode_jsvalue(ei_x_buff *x, JSContext *ctx, JSValue val);

/**
 * Process an incoming message from Erlang.
 *
 * Parses the command tuple, dispatches to the appropriate handler,
 * and sends a response back to the sender.
 *
 * @param fd    Socket file descriptor
 * @param from  Sender's PID
 * @param buf   Message buffer
 * @return      0 to continue, non-zero to stop
 */
int process_message(int fd, erlang_pid *from, ei_x_buff *buf);

/*
 * ============================================================================
 * Command Handlers (erlang_protocol.c)
 * ============================================================================
 *
 * Each command has a dedicated handler function that:
 *   1. Decodes command-specific arguments
 *   2. Performs the requested operation
 *   3. Encodes the response into the buffer
 */

/**
 * Handle 'eval' command - evaluate JavaScript code.
 *
 * @param resp   Response buffer to encode result into
 * @param buf    Message buffer containing code
 * @param index  Current decode position in buffer
 * @return       0 on success
 */
int handle_eval(ei_x_buff *resp, const char *buf, int *index);

/**
 * Handle 'get_output' command - retrieve captured console output.
 *
 * @param resp  Response buffer
 * @return      0 on success
 */
int handle_get_output(ei_x_buff *resp);

/**
 * Handle 'gc' command - trigger garbage collection.
 *
 * @param resp  Response buffer
 * @return      0 on success
 */
int handle_gc(ei_x_buff *resp);

/**
 * Handle 'reset' command - reset JavaScript context.
 *
 * @param resp   Response buffer
 * @param buf    Message buffer containing optional memory size
 * @param index  Current decode position
 * @return       0 on success
 */
int handle_reset(ei_x_buff *resp, const char *buf, int *index);

/**
 * Handle 'stop' command - shutdown the C node.
 *
 * @param resp  Response buffer
 * @return      0 on success
 */
int handle_stop(ei_x_buff *resp);

/*
 * ============================================================================
 * Global State
 * ============================================================================
 */

/** Flag indicating whether the main loop should continue running */
extern volatile int g_running;

#endif /* MQUICKJS_CNODE_H */
