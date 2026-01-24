/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2024-2025. All Rights Reserved.
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
 *
 * %CopyrightEnd%
 */

/*
 * counter_server.c
 *
 * Example gen_wasmserver implementation: A simple counter server.
 *
 * This server maintains a counter value and responds to:
 * - {get} call -> returns current value
 * - {increment} cast -> increments counter
 * - {increment, N} cast -> increments counter by N
 * - {decrement} cast -> decrements counter
 * - {set, N} call -> sets counter to N, returns old value
 * - {reset} cast -> resets counter to initial value
 *
 * Compile with:
 *   clang --target=wasm32-wasi -O2 -I../include \
 *         -nostdlib -Wl,--no-entry -Wl,--export-dynamic \
 *         counter_server.c ../src/erl_wasm_shim.c \
 *         -o counter_server.wasm
 *
 * Usage from Erlang:
 *   {ok, Wasm} = file:read_file("counter_server.wasm"),
 *   {ok, Pid} = gen_wasmserver:start_link(Wasm, 0, []),
 *   gen_wasmserver:call(Pid, get),           %% -> 0
 *   gen_wasmserver:cast(Pid, increment),
 *   gen_wasmserver:call(Pid, get),           %% -> 1
 *   gen_wasmserver:call(Pid, {set, 100}),    %% -> 1
 *   gen_wasmserver:call(Pid, get).           %% -> 100
 */

#include "erl_wasm_shim.h"
#include <stdlib.h>
#include <string.h>

/* ================================================================== */
/*                       Server State                                  */
/* ================================================================== */

/*
 * Our server state is just a counter value.
 * We store it as an Erlang integer term.
 */

/* Initial value stored in process */
static int64_t g_initial_value = 0;

/* ================================================================== */
/*                    Helper Functions                                 */
/* ================================================================== */

/* Decode an integer from a term, defaulting to 1 if not an integer */
static int64_t get_integer_or_default(const erl_term_t *term, int64_t default_val) {
    if (erl_is_integer(term)) {
        return erl_integer_value(term);
    }
    return default_val;
}

/* Encode a counter state (just an integer) */
static erl_wasm_error_t encode_counter_state(int64_t value, uint8_t **data_out, size_t *size_out) {
    erl_term_t *state = erl_mk_integer(value);
    if (!state) return ERL_WASM_ERROR_NOMEM;

    erl_wasm_error_t err = erl_encode_term(state, data_out, size_out);
    erl_free_term(state);
    return err;
}

/* Decode counter state from ETF */
static int64_t decode_counter_state(const uint8_t *data, uint32_t len) {
    erl_term_t *term;
    if (erl_decode_term(data, len, &term) != ERL_WASM_OK) {
        return 0;
    }

    int64_t value = 0;
    if (erl_is_integer(term)) {
        value = erl_integer_value(term);
    }

    erl_free_term(term);
    return value;
}

/* ================================================================== */
/*              gen_wasmserver Callback Implementations                */
/* ================================================================== */

/*
 * wasm_init(Args) -> {ok, State} | {stop, Reason}
 *
 * Initialize the counter with the given value (default 0).
 */
int32_t wasm_init(const uint8_t *args_data, uint32_t args_len,
                  uint8_t **result_data, uint32_t *result_len) {

    /* Decode initial value from args */
    erl_term_t *args;
    int64_t initial = 0;

    if (erl_decode_term(args_data, args_len, &args) == ERL_WASM_OK) {
        if (erl_is_integer(args)) {
            initial = erl_integer_value(args);
        }
        erl_free_term(args);
    }

    /* Remember initial value for reset */
    g_initial_value = initial;

    /* Create initial state */
    erl_term_t *state = erl_mk_integer(initial);
    if (!state) {
        return -1;
    }

    /* Build {ok, State} result */
    size_t size;
    erl_wasm_error_t err = wasm_init_ok(state, result_data, &size);
    *result_len = (uint32_t)size;

    erl_free_term(state);
    return (err == ERL_WASM_OK) ? 0 : -1;
}

/*
 * wasm_handle_call(Request, From, State) -> {reply, Reply, NewState} | ...
 *
 * Handle synchronous calls:
 * - get -> returns current counter value
 * - {set, N} -> sets counter to N, returns old value
 */
int32_t wasm_handle_call(const uint8_t *request_data, uint32_t request_len,
                         const uint8_t *from_data, uint32_t from_len,
                         const uint8_t *state_data, uint32_t state_len,
                         uint8_t **result_data, uint32_t *result_len) {
    (void)from_data;
    (void)from_len;

    /* Decode current state (counter value) */
    int64_t counter = decode_counter_state(state_data, state_len);

    /* Decode request */
    erl_term_t *request;
    if (erl_decode_term(request_data, request_len, &request) != ERL_WASM_OK) {
        return -1;
    }

    erl_term_t *reply = NULL;
    int64_t new_counter = counter;

    /* Handle 'get' atom */
    if (erl_is_atom(request) && erl_atom_eq(request, "get")) {
        reply = erl_mk_integer(counter);
    }
    /* Handle {set, N} tuple */
    else if (erl_is_tuple(request) && erl_tuple_arity(request) == 2) {
        erl_term_t *tag = erl_tuple_element(request, 0);
        erl_term_t *value = erl_tuple_element(request, 1);

        if (erl_is_atom(tag) && erl_atom_eq(tag, "set") && erl_is_integer(value)) {
            reply = erl_mk_integer(counter);  /* Return old value */
            new_counter = erl_integer_value(value);
        }
    }

    erl_free_term(request);

    /* Build reply */
    if (!reply) {
        reply = erl_mk_tuple2(erl_mk_atom("error"), erl_mk_atom("unknown_request"));
        if (!reply) {
            return -1;
        }
    }

    /* Build new state */
    erl_term_t *new_state = erl_mk_integer(new_counter);
    if (!new_state) {
        erl_free_term(reply);
        return -1;
    }

    /* Build {reply, Reply, NewState} result */
    size_t size;
    erl_wasm_error_t err = wasm_call_reply(reply, new_state, result_data, &size);
    *result_len = (uint32_t)size;

    erl_free_term(reply);
    erl_free_term(new_state);

    return (err == ERL_WASM_OK) ? 0 : -1;
}

/*
 * wasm_handle_cast(Request, State) -> {noreply, NewState} | ...
 *
 * Handle asynchronous casts:
 * - increment -> adds 1 to counter
 * - {increment, N} -> adds N to counter
 * - decrement -> subtracts 1 from counter
 * - {decrement, N} -> subtracts N from counter
 * - reset -> resets to initial value
 */
int32_t wasm_handle_cast(const uint8_t *request_data, uint32_t request_len,
                         const uint8_t *state_data, uint32_t state_len,
                         uint8_t **result_data, uint32_t *result_len) {

    /* Decode current state */
    int64_t counter = decode_counter_state(state_data, state_len);

    /* Decode request */
    erl_term_t *request;
    if (erl_decode_term(request_data, request_len, &request) != ERL_WASM_OK) {
        return -1;
    }

    int64_t new_counter = counter;

    /* Handle atoms */
    if (erl_is_atom(request)) {
        if (erl_atom_eq(request, "increment")) {
            new_counter = counter + 1;
        }
        else if (erl_atom_eq(request, "decrement")) {
            new_counter = counter - 1;
        }
        else if (erl_atom_eq(request, "reset")) {
            new_counter = g_initial_value;
        }
    }
    /* Handle tuples */
    else if (erl_is_tuple(request) && erl_tuple_arity(request) == 2) {
        erl_term_t *tag = erl_tuple_element(request, 0);
        erl_term_t *value = erl_tuple_element(request, 1);

        if (erl_is_atom(tag) && erl_is_integer(value)) {
            int64_t n = erl_integer_value(value);
            if (erl_atom_eq(tag, "increment")) {
                new_counter = counter + n;
            }
            else if (erl_atom_eq(tag, "decrement")) {
                new_counter = counter - n;
            }
        }
    }

    erl_free_term(request);

    /* Build new state */
    erl_term_t *new_state = erl_mk_integer(new_counter);
    if (!new_state) {
        return -1;
    }

    /* Build {noreply, NewState} result */
    size_t size;
    erl_wasm_error_t err = wasm_cast_noreply(new_state, result_data, &size);
    *result_len = (uint32_t)size;

    erl_free_term(new_state);

    return (err == ERL_WASM_OK) ? 0 : -1;
}

/*
 * wasm_handle_info(Info, State) -> {noreply, NewState} | ...
 *
 * Handle other messages. For this simple server, we just ignore them.
 */
int32_t wasm_handle_info(const uint8_t *info_data, uint32_t info_len,
                         const uint8_t *state_data, uint32_t state_len,
                         uint8_t **result_data, uint32_t *result_len) {
    (void)info_data;
    (void)info_len;

    /* Just pass through the state unchanged */
    int64_t counter = decode_counter_state(state_data, state_len);

    erl_term_t *new_state = erl_mk_integer(counter);
    if (!new_state) {
        return -1;
    }

    size_t size;
    erl_wasm_error_t err = wasm_cast_noreply(new_state, result_data, &size);
    *result_len = (uint32_t)size;

    erl_free_term(new_state);

    return (err == ERL_WASM_OK) ? 0 : -1;
}

/*
 * wasm_terminate(Reason, State) -> ok
 *
 * Clean up when the server terminates. Nothing to do for this simple server.
 */
int32_t wasm_terminate(const uint8_t *reason_data, uint32_t reason_len,
                       const uint8_t *state_data, uint32_t state_len) {
    (void)reason_data;
    (void)reason_len;
    (void)state_data;
    (void)state_len;

    /* Nothing to clean up */
    return 0;
}

/* ================================================================== */
/*                    WASM Memory Management                           */
/* ================================================================== */

/*
 * These are required exports for memory management.
 * The host calls wasm_alloc to allocate buffers for results.
 */

/* Simple bump allocator for demo purposes */
static uint8_t g_heap[65536];  /* 64KB heap */
static size_t g_heap_ptr = 0;

uint8_t *wasm_alloc(uint32_t size) {
    /* Align to 8 bytes */
    size_t aligned_ptr = (g_heap_ptr + 7) & ~7;
    if (aligned_ptr + size > sizeof(g_heap)) {
        return NULL;  /* Out of memory */
    }
    uint8_t *ptr = &g_heap[aligned_ptr];
    g_heap_ptr = aligned_ptr + size;
    return ptr;
}

void wasm_free(uint8_t *ptr) {
    /* Bump allocator doesn't support individual frees */
    (void)ptr;
}
