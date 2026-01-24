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
 * erl_wasm_shim.h
 *
 * This header provides the interface for WASM modules to interact with
 * Erlang terms using the External Term Format (ETF). It is designed to
 * be compiled into WASM components that implement gen_wasmserver callbacks.
 *
 * The shim provides:
 * - ETF encoding/decoding functions
 * - Type definitions matching Erlang's term structure
 * - Helper macros for common operations
 * - WASI 2 Component Model integration types
 *
 * Usage:
 *   WASM modules should include this header and implement the required
 *   callback functions. The shim handles all ETF encoding/decoding
 *   so WASM code can work with native C types.
 */

#ifndef ERL_WASM_SHIM_H
#define ERL_WASM_SHIM_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================== */
/*                        Version Information                          */
/* ================================================================== */

#define ERL_WASM_SHIM_VERSION_MAJOR 1
#define ERL_WASM_SHIM_VERSION_MINOR 0
#define ERL_WASM_SHIM_VERSION_PATCH 0

/* External Term Format version */
#define ETF_VERSION 131

/* ================================================================== */
/*                        Error Codes                                  */
/* ================================================================== */

typedef enum {
    ERL_WASM_OK = 0,
    ERL_WASM_ERROR = -1,
    ERL_WASM_ERROR_NOMEM = -2,
    ERL_WASM_ERROR_BADARG = -3,
    ERL_WASM_ERROR_DECODE = -4,
    ERL_WASM_ERROR_ENCODE = -5,
    ERL_WASM_ERROR_TYPE = -6,
    ERL_WASM_ERROR_OVERFLOW = -7,
    ERL_WASM_ERROR_TRUNCATED = -8
} erl_wasm_error_t;

/* ================================================================== */
/*                     ETF Type Tags                                   */
/* ================================================================== */

typedef enum {
    ETF_SMALL_INTEGER    = 'a',  /* 97: 0..255 */
    ETF_INTEGER          = 'b',  /* 98: -2^31..2^31-1 */
    ETF_FLOAT            = 'c',  /* 99: old float format (deprecated) */
    ETF_NEW_FLOAT        = 'F',  /* 70: IEEE 754 double */
    ETF_ATOM_DEPRECATED  = 'd',  /* 100: deprecated atom format */
    ETF_SMALL_ATOM_DEPRECATED = 's', /* 115: deprecated small atom */
    ETF_ATOM_UTF8        = 'v',  /* 118: UTF-8 atom */
    ETF_SMALL_ATOM_UTF8  = 'w',  /* 119: small UTF-8 atom */
    ETF_REFERENCE        = 'e',  /* 101: old reference (deprecated) */
    ETF_NEW_REFERENCE    = 'r',  /* 114: new reference (deprecated) */
    ETF_NEWER_REFERENCE  = 'Z',  /* 90: newer reference */
    ETF_PORT             = 'f',  /* 102: old port */
    ETF_NEW_PORT         = 'Y',  /* 89: new port */
    ETF_V4_PORT          = 'x',  /* 120: v4 port */
    ETF_PID              = 'g',  /* 103: old pid */
    ETF_NEW_PID          = 'X',  /* 88: new pid */
    ETF_SMALL_TUPLE      = 'h',  /* 104: tuple with 0..255 elements */
    ETF_LARGE_TUPLE      = 'i',  /* 105: tuple with >255 elements */
    ETF_NIL              = 'j',  /* 106: empty list [] */
    ETF_STRING           = 'k',  /* 107: string (list of bytes) */
    ETF_LIST             = 'l',  /* 108: list */
    ETF_BINARY           = 'm',  /* 109: binary */
    ETF_BIT_BINARY       = 'M',  /* 77: bitstring */
    ETF_SMALL_BIG        = 'n',  /* 110: small bignum */
    ETF_LARGE_BIG        = 'o',  /* 111: large bignum */
    ETF_NEW_FUN          = 'p',  /* 112: new fun */
    ETF_EXPORT           = 'q',  /* 113: export (M:F/A) */
    ETF_MAP              = 't',  /* 116: map */
    ETF_FUN              = 'u',  /* 117: old fun */
    ETF_ATOM_CACHE_REF   = 'R'   /* 82: atom cache reference */
} etf_type_tag_t;

/* ================================================================== */
/*                       Erlang Term Types                             */
/* ================================================================== */

/* Forward declarations */
typedef struct erl_term erl_term_t;
typedef struct erl_list erl_list_t;
typedef struct erl_tuple erl_tuple_t;
typedef struct erl_map erl_map_t;
typedef struct erl_binary erl_binary_t;
typedef struct erl_pid erl_pid_t;
typedef struct erl_ref erl_ref_t;
typedef struct erl_port erl_port_t;

/* Maximum atom length (UTF-8 bytes) */
#define ERL_MAX_ATOM_LENGTH 255

/* Atom representation */
typedef struct {
    uint16_t length;
    char name[ERL_MAX_ATOM_LENGTH + 1];  /* null-terminated */
} erl_atom_t;

/* Binary data */
struct erl_binary {
    uint32_t size;
    uint8_t *data;
};

/* PID (Process Identifier) */
struct erl_pid {
    erl_atom_t node;
    uint32_t num;
    uint32_t serial;
    uint32_t creation;
};

/* Reference */
#define ERL_REF_WORDS 5
struct erl_ref {
    erl_atom_t node;
    uint32_t creation;
    uint8_t len;  /* number of uint32 words */
    uint32_t n[ERL_REF_WORDS];
};

/* Port */
struct erl_port {
    erl_atom_t node;
    uint64_t id;
    uint32_t creation;
};

/* List node */
struct erl_list {
    erl_term_t *head;
    erl_term_t *tail;  /* Can be another list or nil */
};

/* Tuple */
struct erl_tuple {
    uint32_t arity;
    erl_term_t **elements;
};

/* Map entry */
typedef struct {
    erl_term_t *key;
    erl_term_t *value;
} erl_map_entry_t;

/* Map */
struct erl_map {
    uint32_t size;
    erl_map_entry_t *entries;
};

/* Term type enumeration */
typedef enum {
    ERL_TERM_NIL,
    ERL_TERM_ATOM,
    ERL_TERM_INTEGER,
    ERL_TERM_FLOAT,
    ERL_TERM_BINARY,
    ERL_TERM_PID,
    ERL_TERM_REF,
    ERL_TERM_PORT,
    ERL_TERM_LIST,
    ERL_TERM_TUPLE,
    ERL_TERM_MAP,
    ERL_TERM_BITSTRING
} erl_term_type_t;

/* Generic term container */
struct erl_term {
    erl_term_type_t type;
    union {
        int64_t integer;
        double floating;
        erl_atom_t atom;
        erl_binary_t binary;
        erl_pid_t pid;
        erl_ref_t ref;
        erl_port_t port;
        erl_list_t list;
        erl_tuple_t tuple;
        erl_map_t map;
    } value;
};

/* ================================================================== */
/*                    gen_wasmserver Return Types                      */
/* ================================================================== */

/* Return type for init callback */
typedef struct {
    enum {
        INIT_OK,
        INIT_OK_TIMEOUT,
        INIT_OK_HIBERNATE,
        INIT_STOP,
        INIT_ERROR,
        INIT_IGNORE
    } type;
    union {
        struct { erl_term_t *state; } ok;
        struct { erl_term_t *state; uint32_t timeout_ms; } ok_timeout;
        struct { erl_term_t *state; } ok_hibernate;
        struct { erl_term_t *reason; } stop;
        struct { erl_term_t *reason; } error;
    } data;
} wasm_init_result_t;

/* Return type for handle_call callback */
typedef struct {
    enum {
        CALL_REPLY,
        CALL_REPLY_TIMEOUT,
        CALL_REPLY_HIBERNATE,
        CALL_NOREPLY,
        CALL_NOREPLY_TIMEOUT,
        CALL_NOREPLY_HIBERNATE,
        CALL_STOP_REPLY,
        CALL_STOP
    } type;
    union {
        struct { erl_term_t *reply; erl_term_t *state; } reply;
        struct { erl_term_t *reply; erl_term_t *state; uint32_t timeout_ms; } reply_timeout;
        struct { erl_term_t *reply; erl_term_t *state; } reply_hibernate;
        struct { erl_term_t *state; } noreply;
        struct { erl_term_t *state; uint32_t timeout_ms; } noreply_timeout;
        struct { erl_term_t *state; } noreply_hibernate;
        struct { erl_term_t *reason; erl_term_t *reply; erl_term_t *state; } stop_reply;
        struct { erl_term_t *reason; erl_term_t *state; } stop;
    } data;
} wasm_call_result_t;

/* Return type for handle_cast/handle_info callbacks */
typedef struct {
    enum {
        CAST_NOREPLY,
        CAST_NOREPLY_TIMEOUT,
        CAST_NOREPLY_HIBERNATE,
        CAST_STOP
    } type;
    union {
        struct { erl_term_t *state; } noreply;
        struct { erl_term_t *state; uint32_t timeout_ms; } noreply_timeout;
        struct { erl_term_t *state; } noreply_hibernate;
        struct { erl_term_t *reason; erl_term_t *state; } stop;
    } data;
} wasm_cast_result_t;

/* ================================================================== */
/*                     Memory Management                               */
/* ================================================================== */

/*
 * Allocate memory for a term.
 * Returns NULL on failure.
 */
erl_term_t *erl_alloc_term(void);

/*
 * Free a term and all nested terms.
 */
void erl_free_term(erl_term_t *term);

/*
 * Allocate a binary buffer.
 */
erl_binary_t *erl_alloc_binary(uint32_t size);

/*
 * Free a binary buffer.
 */
void erl_free_binary(erl_binary_t *bin);

/* ================================================================== */
/*                      Term Construction                              */
/* ================================================================== */

/*
 * Create common Erlang terms.
 * All functions return NULL on allocation failure.
 */

/* Create nil (empty list) */
erl_term_t *erl_mk_nil(void);

/* Create an atom from a null-terminated string */
erl_term_t *erl_mk_atom(const char *name);

/* Create an atom from a string with length */
erl_term_t *erl_mk_atom_len(const char *name, size_t len);

/* Create an integer */
erl_term_t *erl_mk_integer(int64_t value);

/* Create a float */
erl_term_t *erl_mk_float(double value);

/* Create a boolean (atoms 'true' or 'false') */
erl_term_t *erl_mk_boolean(bool value);

/* Create a binary from data */
erl_term_t *erl_mk_binary(const uint8_t *data, uint32_t size);

/* Create a string as a list of integers */
erl_term_t *erl_mk_string(const char *str);

/* Create a string with length */
erl_term_t *erl_mk_string_len(const char *str, size_t len);

/* Create a list from an array of terms (NULL-terminated) */
erl_term_t *erl_mk_list(erl_term_t **elements);

/* Create a list with explicit count */
erl_term_t *erl_mk_list_n(erl_term_t **elements, size_t count);

/* Cons (prepend) an element to a list */
erl_term_t *erl_cons(erl_term_t *head, erl_term_t *tail);

/* Create a tuple from an array of terms */
erl_term_t *erl_mk_tuple(erl_term_t **elements, uint32_t arity);

/* Create a 2-tuple */
erl_term_t *erl_mk_tuple2(erl_term_t *e1, erl_term_t *e2);

/* Create a 3-tuple */
erl_term_t *erl_mk_tuple3(erl_term_t *e1, erl_term_t *e2, erl_term_t *e3);

/* Create a 4-tuple */
erl_term_t *erl_mk_tuple4(erl_term_t *e1, erl_term_t *e2, erl_term_t *e3, erl_term_t *e4);

/* Create a map from an array of key-value pairs */
erl_term_t *erl_mk_map(erl_map_entry_t *entries, uint32_t size);

/* Create a map entry */
erl_map_entry_t erl_mk_map_entry(erl_term_t *key, erl_term_t *value);

/* Create a PID */
erl_term_t *erl_mk_pid(const char *node, uint32_t num, uint32_t serial, uint32_t creation);

/* ================================================================== */
/*                      Term Inspection                                */
/* ================================================================== */

/* Type checking */
bool erl_is_nil(const erl_term_t *term);
bool erl_is_atom(const erl_term_t *term);
bool erl_is_integer(const erl_term_t *term);
bool erl_is_float(const erl_term_t *term);
bool erl_is_number(const erl_term_t *term);
bool erl_is_binary(const erl_term_t *term);
bool erl_is_list(const erl_term_t *term);
bool erl_is_tuple(const erl_term_t *term);
bool erl_is_map(const erl_term_t *term);
bool erl_is_pid(const erl_term_t *term);
bool erl_is_ref(const erl_term_t *term);
bool erl_is_port(const erl_term_t *term);

/* Atom inspection */
bool erl_atom_eq(const erl_term_t *term, const char *name);
const char *erl_atom_name(const erl_term_t *term);
size_t erl_atom_length(const erl_term_t *term);

/* Integer extraction */
int64_t erl_integer_value(const erl_term_t *term);

/* Float extraction */
double erl_float_value(const erl_term_t *term);

/* Binary inspection */
const uint8_t *erl_binary_data(const erl_term_t *term);
uint32_t erl_binary_size(const erl_term_t *term);

/* List inspection */
erl_term_t *erl_hd(const erl_term_t *list);
erl_term_t *erl_tl(const erl_term_t *list);
uint32_t erl_list_length(const erl_term_t *list);

/* Tuple inspection */
uint32_t erl_tuple_arity(const erl_term_t *tuple);
erl_term_t *erl_tuple_element(const erl_term_t *tuple, uint32_t index);

/* Map inspection */
uint32_t erl_map_size(const erl_term_t *map);
erl_term_t *erl_map_get(const erl_term_t *map, const erl_term_t *key);
bool erl_map_has_key(const erl_term_t *map, const erl_term_t *key);

/* PID inspection */
const char *erl_pid_node(const erl_term_t *term);
uint32_t erl_pid_num(const erl_term_t *term);

/* ================================================================== */
/*                     ETF Encoding/Decoding                           */
/* ================================================================== */

/*
 * Decode an ETF binary into a term structure.
 *
 * @param data     Pointer to ETF binary data
 * @param size     Size of the data in bytes
 * @param term_out Output pointer for the decoded term
 * @return         ERL_WASM_OK on success, error code otherwise
 */
erl_wasm_error_t erl_decode_term(const uint8_t *data, size_t size, erl_term_t **term_out);

/*
 * Encode a term to ETF binary format.
 *
 * @param term     Term to encode
 * @param data_out Output pointer for the encoded data (caller must free)
 * @param size_out Output pointer for the size of encoded data
 * @return         ERL_WASM_OK on success, error code otherwise
 */
erl_wasm_error_t erl_encode_term(const erl_term_t *term, uint8_t **data_out, size_t *size_out);

/*
 * Calculate the encoded size of a term (without actually encoding).
 */
size_t erl_encoded_size(const erl_term_t *term);

/* ================================================================== */
/*                    gen_wasmserver Result Builders                   */
/* ================================================================== */

/*
 * Build init result: {ok, State}
 */
erl_wasm_error_t wasm_init_ok(erl_term_t *state, uint8_t **data_out, size_t *size_out);

/*
 * Build init result: {ok, State, Timeout}
 */
erl_wasm_error_t wasm_init_ok_timeout(erl_term_t *state, uint32_t timeout_ms,
                                      uint8_t **data_out, size_t *size_out);

/*
 * Build init result: {ok, State, hibernate}
 */
erl_wasm_error_t wasm_init_ok_hibernate(erl_term_t *state,
                                        uint8_t **data_out, size_t *size_out);

/*
 * Build init result: {stop, Reason}
 */
erl_wasm_error_t wasm_init_stop(erl_term_t *reason, uint8_t **data_out, size_t *size_out);

/*
 * Build init result: ignore
 */
erl_wasm_error_t wasm_init_ignore(uint8_t **data_out, size_t *size_out);

/*
 * Build call result: {reply, Reply, NewState}
 */
erl_wasm_error_t wasm_call_reply(erl_term_t *reply, erl_term_t *state,
                                 uint8_t **data_out, size_t *size_out);

/*
 * Build call result: {reply, Reply, NewState, Timeout}
 */
erl_wasm_error_t wasm_call_reply_timeout(erl_term_t *reply, erl_term_t *state,
                                         uint32_t timeout_ms,
                                         uint8_t **data_out, size_t *size_out);

/*
 * Build call result: {reply, Reply, NewState, hibernate}
 */
erl_wasm_error_t wasm_call_reply_hibernate(erl_term_t *reply, erl_term_t *state,
                                           uint8_t **data_out, size_t *size_out);

/*
 * Build call result: {noreply, NewState}
 */
erl_wasm_error_t wasm_call_noreply(erl_term_t *state, uint8_t **data_out, size_t *size_out);

/*
 * Build call result: {stop, Reason, Reply, NewState}
 */
erl_wasm_error_t wasm_call_stop_reply(erl_term_t *reason, erl_term_t *reply,
                                      erl_term_t *state,
                                      uint8_t **data_out, size_t *size_out);

/*
 * Build call result: {stop, Reason, NewState}
 */
erl_wasm_error_t wasm_call_stop(erl_term_t *reason, erl_term_t *state,
                                uint8_t **data_out, size_t *size_out);

/*
 * Build cast/info result: {noreply, NewState}
 */
erl_wasm_error_t wasm_cast_noreply(erl_term_t *state, uint8_t **data_out, size_t *size_out);

/*
 * Build cast/info result: {noreply, NewState, Timeout}
 */
erl_wasm_error_t wasm_cast_noreply_timeout(erl_term_t *state, uint32_t timeout_ms,
                                           uint8_t **data_out, size_t *size_out);

/*
 * Build cast/info result: {noreply, NewState, hibernate}
 */
erl_wasm_error_t wasm_cast_noreply_hibernate(erl_term_t *state,
                                             uint8_t **data_out, size_t *size_out);

/*
 * Build cast/info result: {stop, Reason, NewState}
 */
erl_wasm_error_t wasm_cast_stop(erl_term_t *reason, erl_term_t *state,
                                uint8_t **data_out, size_t *size_out);

/* ================================================================== */
/*                     Utility Functions                               */
/* ================================================================== */

/*
 * Get the last error message (thread-local).
 */
const char *erl_wasm_strerror(erl_wasm_error_t error);

/*
 * Deep copy a term.
 */
erl_term_t *erl_copy_term(const erl_term_t *term);

/*
 * Compare two terms for equality.
 */
bool erl_terms_equal(const erl_term_t *a, const erl_term_t *b);

/*
 * Print a term to a string buffer (for debugging).
 */
int erl_term_to_string(const erl_term_t *term, char *buf, size_t buf_size);

/* ================================================================== */
/*               WASM Component Model Entry Points                     */
/* ================================================================== */

/*
 * These are the functions that WASM modules must implement.
 * They receive ETF-encoded data and must return ETF-encoded results.
 */

/*
 * Initialize the server state.
 *
 * @param args_data   ETF-encoded initialization arguments
 * @param args_len    Length of args_data
 * @param result_data Output: ETF-encoded result tuple
 * @param result_len  Output: Length of result_data
 * @return            0 on success, non-zero on error
 *
 * Expected return (ETF-encoded):
 *   {ok, State} | {ok, State, timeout() | hibernate} | {stop, Reason} | ignore
 */
__attribute__((export_name("wasm_init")))
int32_t wasm_init(const uint8_t *args_data, uint32_t args_len,
                  uint8_t **result_data, uint32_t *result_len);

/*
 * Handle a synchronous call.
 *
 * @param request_data  ETF-encoded request
 * @param request_len   Length of request_data
 * @param from_data     ETF-encoded {Pid, Tag} tuple
 * @param from_len      Length of from_data
 * @param state_data    ETF-encoded current state
 * @param state_len     Length of state_data
 * @param result_data   Output: ETF-encoded result tuple
 * @param result_len    Output: Length of result_data
 * @return              0 on success, non-zero on error
 *
 * Expected return (ETF-encoded):
 *   {reply, Reply, NewState} |
 *   {reply, Reply, NewState, timeout() | hibernate} |
 *   {noreply, NewState} |
 *   {noreply, NewState, timeout() | hibernate} |
 *   {stop, Reason, Reply, NewState} |
 *   {stop, Reason, NewState}
 */
__attribute__((export_name("wasm_handle_call")))
int32_t wasm_handle_call(const uint8_t *request_data, uint32_t request_len,
                         const uint8_t *from_data, uint32_t from_len,
                         const uint8_t *state_data, uint32_t state_len,
                         uint8_t **result_data, uint32_t *result_len);

/*
 * Handle an asynchronous cast.
 *
 * @param request_data  ETF-encoded request
 * @param request_len   Length of request_data
 * @param state_data    ETF-encoded current state
 * @param state_len     Length of state_data
 * @param result_data   Output: ETF-encoded result tuple
 * @param result_len    Output: Length of result_data
 * @return              0 on success, non-zero on error
 *
 * Expected return (ETF-encoded):
 *   {noreply, NewState} |
 *   {noreply, NewState, timeout() | hibernate} |
 *   {stop, Reason, NewState}
 */
__attribute__((export_name("wasm_handle_cast")))
int32_t wasm_handle_cast(const uint8_t *request_data, uint32_t request_len,
                         const uint8_t *state_data, uint32_t state_len,
                         uint8_t **result_data, uint32_t *result_len);

/*
 * Handle other messages (info).
 *
 * @param info_data     ETF-encoded message
 * @param info_len      Length of info_data
 * @param state_data    ETF-encoded current state
 * @param state_len     Length of state_data
 * @param result_data   Output: ETF-encoded result tuple
 * @param result_len    Output: Length of result_data
 * @return              0 on success, non-zero on error
 *
 * Expected return (ETF-encoded):
 *   {noreply, NewState} |
 *   {noreply, NewState, timeout() | hibernate} |
 *   {stop, Reason, NewState}
 */
__attribute__((export_name("wasm_handle_info")))
int32_t wasm_handle_info(const uint8_t *info_data, uint32_t info_len,
                         const uint8_t *state_data, uint32_t state_len,
                         uint8_t **result_data, uint32_t *result_len);

/*
 * Handle termination.
 *
 * @param reason_data   ETF-encoded termination reason
 * @param reason_len    Length of reason_data
 * @param state_data    ETF-encoded current state
 * @param state_len     Length of state_data
 * @return              0 on success, non-zero on error
 */
__attribute__((export_name("wasm_terminate")))
int32_t wasm_terminate(const uint8_t *reason_data, uint32_t reason_len,
                       const uint8_t *state_data, uint32_t state_len);

/* ================================================================== */
/*                    WASM Memory Management                           */
/* ================================================================== */

/*
 * Allocate memory from WASM linear memory.
 * This is called by the host to allocate buffers for results.
 */
__attribute__((export_name("wasm_alloc")))
uint8_t *wasm_alloc(uint32_t size);

/*
 * Free memory in WASM linear memory.
 */
__attribute__((export_name("wasm_free")))
void wasm_free(uint8_t *ptr);

#ifdef __cplusplus
}
#endif

#endif /* ERL_WASM_SHIM_H */
