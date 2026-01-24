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
 * erl_wasm_shim.c
 *
 * Implementation of the Erlang WASM shim for gen_wasmserver.
 * This file provides ETF encoding/decoding and term manipulation functions.
 */

#include "erl_wasm_shim.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ================================================================== */
/*                    Internal Buffer Management                       */
/* ================================================================== */

typedef struct {
    uint8_t *data;
    size_t size;
    size_t capacity;
    size_t pos;  /* For decoding */
} buffer_t;

static buffer_t *buffer_new(size_t initial_capacity) {
    buffer_t *buf = (buffer_t *)malloc(sizeof(buffer_t));
    if (!buf) return NULL;

    buf->data = (uint8_t *)malloc(initial_capacity);
    if (!buf->data) {
        free(buf);
        return NULL;
    }

    buf->size = 0;
    buf->capacity = initial_capacity;
    buf->pos = 0;
    return buf;
}

static buffer_t *buffer_wrap(const uint8_t *data, size_t size) {
    buffer_t *buf = (buffer_t *)malloc(sizeof(buffer_t));
    if (!buf) return NULL;

    buf->data = (uint8_t *)data;  /* Note: not copied */
    buf->size = size;
    buf->capacity = size;
    buf->pos = 0;
    return buf;
}

static void buffer_free(buffer_t *buf) {
    if (buf) {
        free(buf->data);
        free(buf);
    }
}

static void buffer_free_wrap(buffer_t *buf) {
    if (buf) {
        free(buf);  /* Don't free data for wrapped buffers */
    }
}

static int buffer_ensure(buffer_t *buf, size_t additional) {
    if (buf->size + additional > buf->capacity) {
        size_t new_capacity = buf->capacity * 2;
        if (new_capacity < buf->size + additional) {
            new_capacity = buf->size + additional;
        }
        uint8_t *new_data = (uint8_t *)realloc(buf->data, new_capacity);
        if (!new_data) return -1;
        buf->data = new_data;
        buf->capacity = new_capacity;
    }
    return 0;
}

static int buffer_write_byte(buffer_t *buf, uint8_t byte) {
    if (buffer_ensure(buf, 1) < 0) return -1;
    buf->data[buf->size++] = byte;
    return 0;
}

static int buffer_write_bytes(buffer_t *buf, const uint8_t *data, size_t len) {
    if (buffer_ensure(buf, len) < 0) return -1;
    memcpy(buf->data + buf->size, data, len);
    buf->size += len;
    return 0;
}

static int buffer_write_uint16_be(buffer_t *buf, uint16_t value) {
    uint8_t bytes[2];
    bytes[0] = (value >> 8) & 0xFF;
    bytes[1] = value & 0xFF;
    return buffer_write_bytes(buf, bytes, 2);
}

static int buffer_write_uint32_be(buffer_t *buf, uint32_t value) {
    uint8_t bytes[4];
    bytes[0] = (value >> 24) & 0xFF;
    bytes[1] = (value >> 16) & 0xFF;
    bytes[2] = (value >> 8) & 0xFF;
    bytes[3] = value & 0xFF;
    return buffer_write_bytes(buf, bytes, 4);
}

static int buffer_read_byte(buffer_t *buf, uint8_t *byte) {
    if (buf->pos >= buf->size) return -1;
    *byte = buf->data[buf->pos++];
    return 0;
}

static int buffer_read_bytes(buffer_t *buf, uint8_t *data, size_t len) {
    if (buf->pos + len > buf->size) return -1;
    memcpy(data, buf->data + buf->pos, len);
    buf->pos += len;
    return 0;
}

static int buffer_read_uint16_be(buffer_t *buf, uint16_t *value) {
    uint8_t bytes[2];
    if (buffer_read_bytes(buf, bytes, 2) < 0) return -1;
    *value = ((uint16_t)bytes[0] << 8) | bytes[1];
    return 0;
}

static int buffer_read_uint32_be(buffer_t *buf, uint32_t *value) {
    uint8_t bytes[4];
    if (buffer_read_bytes(buf, bytes, 4) < 0) return -1;
    *value = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
             ((uint32_t)bytes[2] << 8) | bytes[3];
    return 0;
}

static int buffer_read_int32_be(buffer_t *buf, int32_t *value) {
    return buffer_read_uint32_be(buf, (uint32_t *)value);
}

/* ================================================================== */
/*                     Memory Management                               */
/* ================================================================== */

erl_term_t *erl_alloc_term(void) {
    erl_term_t *term = (erl_term_t *)calloc(1, sizeof(erl_term_t));
    return term;
}

void erl_free_term(erl_term_t *term) {
    if (!term) return;

    switch (term->type) {
        case ERL_TERM_BINARY:
            if (term->value.binary.data) {
                free(term->value.binary.data);
            }
            break;
        case ERL_TERM_LIST:
            erl_free_term(term->value.list.head);
            erl_free_term(term->value.list.tail);
            break;
        case ERL_TERM_TUPLE:
            for (uint32_t i = 0; i < term->value.tuple.arity; i++) {
                erl_free_term(term->value.tuple.elements[i]);
            }
            free(term->value.tuple.elements);
            break;
        case ERL_TERM_MAP:
            for (uint32_t i = 0; i < term->value.map.size; i++) {
                erl_free_term(term->value.map.entries[i].key);
                erl_free_term(term->value.map.entries[i].value);
            }
            free(term->value.map.entries);
            break;
        default:
            break;
    }

    free(term);
}

erl_binary_t *erl_alloc_binary(uint32_t size) {
    erl_binary_t *bin = (erl_binary_t *)malloc(sizeof(erl_binary_t));
    if (!bin) return NULL;

    bin->size = size;
    bin->data = (uint8_t *)malloc(size);
    if (!bin->data) {
        free(bin);
        return NULL;
    }

    return bin;
}

void erl_free_binary(erl_binary_t *bin) {
    if (bin) {
        free(bin->data);
        free(bin);
    }
}

/* ================================================================== */
/*                      Term Construction                              */
/* ================================================================== */

erl_term_t *erl_mk_nil(void) {
    erl_term_t *term = erl_alloc_term();
    if (term) {
        term->type = ERL_TERM_NIL;
    }
    return term;
}

erl_term_t *erl_mk_atom(const char *name) {
    return erl_mk_atom_len(name, strlen(name));
}

erl_term_t *erl_mk_atom_len(const char *name, size_t len) {
    if (len > ERL_MAX_ATOM_LENGTH) return NULL;

    erl_term_t *term = erl_alloc_term();
    if (!term) return NULL;

    term->type = ERL_TERM_ATOM;
    term->value.atom.length = (uint16_t)len;
    memcpy(term->value.atom.name, name, len);
    term->value.atom.name[len] = '\0';

    return term;
}

erl_term_t *erl_mk_integer(int64_t value) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return NULL;

    term->type = ERL_TERM_INTEGER;
    term->value.integer = value;

    return term;
}

erl_term_t *erl_mk_float(double value) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return NULL;

    term->type = ERL_TERM_FLOAT;
    term->value.floating = value;

    return term;
}

erl_term_t *erl_mk_boolean(bool value) {
    return erl_mk_atom(value ? "true" : "false");
}

erl_term_t *erl_mk_binary(const uint8_t *data, uint32_t size) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return NULL;

    term->type = ERL_TERM_BINARY;
    term->value.binary.size = size;
    term->value.binary.data = (uint8_t *)malloc(size);
    if (!term->value.binary.data) {
        free(term);
        return NULL;
    }

    memcpy(term->value.binary.data, data, size);
    return term;
}

erl_term_t *erl_mk_string(const char *str) {
    return erl_mk_string_len(str, strlen(str));
}

erl_term_t *erl_mk_string_len(const char *str, size_t len) {
    /* Build a list of integers */
    erl_term_t *list = erl_mk_nil();
    if (!list) return NULL;

    /* Build list in reverse, then it's already correct order due to cons */
    for (int i = (int)len - 1; i >= 0; i--) {
        erl_term_t *ch = erl_mk_integer((unsigned char)str[i]);
        if (!ch) {
            erl_free_term(list);
            return NULL;
        }
        erl_term_t *new_list = erl_cons(ch, list);
        if (!new_list) {
            erl_free_term(ch);
            erl_free_term(list);
            return NULL;
        }
        list = new_list;
    }

    return list;
}

erl_term_t *erl_mk_list(erl_term_t **elements) {
    size_t count = 0;
    while (elements[count]) count++;
    return erl_mk_list_n(elements, count);
}

erl_term_t *erl_mk_list_n(erl_term_t **elements, size_t count) {
    erl_term_t *list = erl_mk_nil();
    if (!list) return NULL;

    for (int i = (int)count - 1; i >= 0; i--) {
        erl_term_t *new_list = erl_cons(elements[i], list);
        if (!new_list) {
            erl_free_term(list);
            return NULL;
        }
        list = new_list;
    }

    return list;
}

erl_term_t *erl_cons(erl_term_t *head, erl_term_t *tail) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return NULL;

    term->type = ERL_TERM_LIST;
    term->value.list.head = head;
    term->value.list.tail = tail;

    return term;
}

erl_term_t *erl_mk_tuple(erl_term_t **elements, uint32_t arity) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return NULL;

    term->type = ERL_TERM_TUPLE;
    term->value.tuple.arity = arity;
    term->value.tuple.elements = (erl_term_t **)malloc(arity * sizeof(erl_term_t *));
    if (!term->value.tuple.elements) {
        free(term);
        return NULL;
    }

    for (uint32_t i = 0; i < arity; i++) {
        term->value.tuple.elements[i] = elements[i];
    }

    return term;
}

erl_term_t *erl_mk_tuple2(erl_term_t *e1, erl_term_t *e2) {
    erl_term_t *elements[2] = {e1, e2};
    return erl_mk_tuple(elements, 2);
}

erl_term_t *erl_mk_tuple3(erl_term_t *e1, erl_term_t *e2, erl_term_t *e3) {
    erl_term_t *elements[3] = {e1, e2, e3};
    return erl_mk_tuple(elements, 3);
}

erl_term_t *erl_mk_tuple4(erl_term_t *e1, erl_term_t *e2, erl_term_t *e3, erl_term_t *e4) {
    erl_term_t *elements[4] = {e1, e2, e3, e4};
    return erl_mk_tuple(elements, 4);
}

erl_term_t *erl_mk_map(erl_map_entry_t *entries, uint32_t size) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return NULL;

    term->type = ERL_TERM_MAP;
    term->value.map.size = size;
    term->value.map.entries = (erl_map_entry_t *)malloc(size * sizeof(erl_map_entry_t));
    if (!term->value.map.entries) {
        free(term);
        return NULL;
    }

    memcpy(term->value.map.entries, entries, size * sizeof(erl_map_entry_t));
    return term;
}

erl_map_entry_t erl_mk_map_entry(erl_term_t *key, erl_term_t *value) {
    erl_map_entry_t entry;
    entry.key = key;
    entry.value = value;
    return entry;
}

erl_term_t *erl_mk_pid(const char *node, uint32_t num, uint32_t serial, uint32_t creation) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return NULL;

    term->type = ERL_TERM_PID;
    size_t node_len = strlen(node);
    if (node_len > ERL_MAX_ATOM_LENGTH) {
        free(term);
        return NULL;
    }
    term->value.pid.node.length = (uint16_t)node_len;
    memcpy(term->value.pid.node.name, node, node_len + 1);
    term->value.pid.num = num;
    term->value.pid.serial = serial;
    term->value.pid.creation = creation;

    return term;
}

/* ================================================================== */
/*                      Term Inspection                                */
/* ================================================================== */

bool erl_is_nil(const erl_term_t *term) {
    return term && term->type == ERL_TERM_NIL;
}

bool erl_is_atom(const erl_term_t *term) {
    return term && term->type == ERL_TERM_ATOM;
}

bool erl_is_integer(const erl_term_t *term) {
    return term && term->type == ERL_TERM_INTEGER;
}

bool erl_is_float(const erl_term_t *term) {
    return term && term->type == ERL_TERM_FLOAT;
}

bool erl_is_number(const erl_term_t *term) {
    return erl_is_integer(term) || erl_is_float(term);
}

bool erl_is_binary(const erl_term_t *term) {
    return term && term->type == ERL_TERM_BINARY;
}

bool erl_is_list(const erl_term_t *term) {
    return term && (term->type == ERL_TERM_LIST || term->type == ERL_TERM_NIL);
}

bool erl_is_tuple(const erl_term_t *term) {
    return term && term->type == ERL_TERM_TUPLE;
}

bool erl_is_map(const erl_term_t *term) {
    return term && term->type == ERL_TERM_MAP;
}

bool erl_is_pid(const erl_term_t *term) {
    return term && term->type == ERL_TERM_PID;
}

bool erl_is_ref(const erl_term_t *term) {
    return term && term->type == ERL_TERM_REF;
}

bool erl_is_port(const erl_term_t *term) {
    return term && term->type == ERL_TERM_PORT;
}

bool erl_atom_eq(const erl_term_t *term, const char *name) {
    if (!erl_is_atom(term)) return false;
    return strcmp(term->value.atom.name, name) == 0;
}

const char *erl_atom_name(const erl_term_t *term) {
    if (!erl_is_atom(term)) return NULL;
    return term->value.atom.name;
}

size_t erl_atom_length(const erl_term_t *term) {
    if (!erl_is_atom(term)) return 0;
    return term->value.atom.length;
}

int64_t erl_integer_value(const erl_term_t *term) {
    if (!erl_is_integer(term)) return 0;
    return term->value.integer;
}

double erl_float_value(const erl_term_t *term) {
    if (!erl_is_float(term)) return 0.0;
    return term->value.floating;
}

const uint8_t *erl_binary_data(const erl_term_t *term) {
    if (!erl_is_binary(term)) return NULL;
    return term->value.binary.data;
}

uint32_t erl_binary_size(const erl_term_t *term) {
    if (!erl_is_binary(term)) return 0;
    return term->value.binary.size;
}

erl_term_t *erl_hd(const erl_term_t *list) {
    if (!list || list->type != ERL_TERM_LIST) return NULL;
    return list->value.list.head;
}

erl_term_t *erl_tl(const erl_term_t *list) {
    if (!list || list->type != ERL_TERM_LIST) return NULL;
    return list->value.list.tail;
}

uint32_t erl_list_length(const erl_term_t *list) {
    uint32_t len = 0;
    const erl_term_t *curr = list;
    while (curr && curr->type == ERL_TERM_LIST) {
        len++;
        curr = curr->value.list.tail;
    }
    return len;
}

uint32_t erl_tuple_arity(const erl_term_t *tuple) {
    if (!erl_is_tuple(tuple)) return 0;
    return tuple->value.tuple.arity;
}

erl_term_t *erl_tuple_element(const erl_term_t *tuple, uint32_t index) {
    if (!erl_is_tuple(tuple)) return NULL;
    if (index >= tuple->value.tuple.arity) return NULL;
    return tuple->value.tuple.elements[index];
}

uint32_t erl_map_size(const erl_term_t *map) {
    if (!erl_is_map(map)) return 0;
    return map->value.map.size;
}

erl_term_t *erl_map_get(const erl_term_t *map, const erl_term_t *key) {
    if (!erl_is_map(map)) return NULL;
    for (uint32_t i = 0; i < map->value.map.size; i++) {
        if (erl_terms_equal(map->value.map.entries[i].key, key)) {
            return map->value.map.entries[i].value;
        }
    }
    return NULL;
}

bool erl_map_has_key(const erl_term_t *map, const erl_term_t *key) {
    return erl_map_get(map, key) != NULL;
}

const char *erl_pid_node(const erl_term_t *term) {
    if (!erl_is_pid(term)) return NULL;
    return term->value.pid.node.name;
}

uint32_t erl_pid_num(const erl_term_t *term) {
    if (!erl_is_pid(term)) return 0;
    return term->value.pid.num;
}

/* ================================================================== */
/*                     ETF Decoding                                    */
/* ================================================================== */

static erl_wasm_error_t decode_term_internal(buffer_t *buf, erl_term_t **term_out);

static erl_wasm_error_t decode_atom(buffer_t *buf, etf_type_tag_t tag, erl_term_t **term_out) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return ERL_WASM_ERROR_NOMEM;

    term->type = ERL_TERM_ATOM;
    uint16_t len;

    if (tag == ETF_SMALL_ATOM_UTF8 || tag == ETF_SMALL_ATOM_DEPRECATED) {
        uint8_t small_len;
        if (buffer_read_byte(buf, &small_len) < 0) {
            free(term);
            return ERL_WASM_ERROR_TRUNCATED;
        }
        len = small_len;
    } else {
        if (buffer_read_uint16_be(buf, &len) < 0) {
            free(term);
            return ERL_WASM_ERROR_TRUNCATED;
        }
    }

    if (len > ERL_MAX_ATOM_LENGTH) {
        free(term);
        return ERL_WASM_ERROR_OVERFLOW;
    }

    term->value.atom.length = len;
    if (buffer_read_bytes(buf, (uint8_t *)term->value.atom.name, len) < 0) {
        free(term);
        return ERL_WASM_ERROR_TRUNCATED;
    }
    term->value.atom.name[len] = '\0';

    *term_out = term;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_integer(buffer_t *buf, etf_type_tag_t tag, erl_term_t **term_out) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return ERL_WASM_ERROR_NOMEM;

    term->type = ERL_TERM_INTEGER;

    if (tag == ETF_SMALL_INTEGER) {
        uint8_t val;
        if (buffer_read_byte(buf, &val) < 0) {
            free(term);
            return ERL_WASM_ERROR_TRUNCATED;
        }
        term->value.integer = val;
    } else {
        int32_t val;
        if (buffer_read_int32_be(buf, &val) < 0) {
            free(term);
            return ERL_WASM_ERROR_TRUNCATED;
        }
        term->value.integer = val;
    }

    *term_out = term;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_float(buffer_t *buf, erl_term_t **term_out) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return ERL_WASM_ERROR_NOMEM;

    term->type = ERL_TERM_FLOAT;

    /* IEEE 754 double in big-endian */
    uint8_t bytes[8];
    if (buffer_read_bytes(buf, bytes, 8) < 0) {
        free(term);
        return ERL_WASM_ERROR_TRUNCATED;
    }

    /* Convert big-endian to native */
    uint64_t bits = 0;
    for (int i = 0; i < 8; i++) {
        bits = (bits << 8) | bytes[i];
    }
    memcpy(&term->value.floating, &bits, sizeof(double));

    *term_out = term;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_binary(buffer_t *buf, erl_term_t **term_out) {
    uint32_t len;
    if (buffer_read_uint32_be(buf, &len) < 0) {
        return ERL_WASM_ERROR_TRUNCATED;
    }

    erl_term_t *term = erl_alloc_term();
    if (!term) return ERL_WASM_ERROR_NOMEM;

    term->type = ERL_TERM_BINARY;
    term->value.binary.size = len;
    term->value.binary.data = (uint8_t *)malloc(len);
    if (!term->value.binary.data) {
        free(term);
        return ERL_WASM_ERROR_NOMEM;
    }

    if (buffer_read_bytes(buf, term->value.binary.data, len) < 0) {
        free(term->value.binary.data);
        free(term);
        return ERL_WASM_ERROR_TRUNCATED;
    }

    *term_out = term;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_tuple(buffer_t *buf, etf_type_tag_t tag, erl_term_t **term_out) {
    uint32_t arity;

    if (tag == ETF_SMALL_TUPLE) {
        uint8_t small_arity;
        if (buffer_read_byte(buf, &small_arity) < 0) {
            return ERL_WASM_ERROR_TRUNCATED;
        }
        arity = small_arity;
    } else {
        if (buffer_read_uint32_be(buf, &arity) < 0) {
            return ERL_WASM_ERROR_TRUNCATED;
        }
    }

    erl_term_t *term = erl_alloc_term();
    if (!term) return ERL_WASM_ERROR_NOMEM;

    term->type = ERL_TERM_TUPLE;
    term->value.tuple.arity = arity;
    term->value.tuple.elements = (erl_term_t **)calloc(arity, sizeof(erl_term_t *));
    if (!term->value.tuple.elements) {
        free(term);
        return ERL_WASM_ERROR_NOMEM;
    }

    for (uint32_t i = 0; i < arity; i++) {
        erl_wasm_error_t err = decode_term_internal(buf, &term->value.tuple.elements[i]);
        if (err != ERL_WASM_OK) {
            erl_free_term(term);
            return err;
        }
    }

    *term_out = term;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_nil(erl_term_t **term_out) {
    *term_out = erl_mk_nil();
    return *term_out ? ERL_WASM_OK : ERL_WASM_ERROR_NOMEM;
}

static erl_wasm_error_t decode_list(buffer_t *buf, erl_term_t **term_out) {
    uint32_t len;
    if (buffer_read_uint32_be(buf, &len) < 0) {
        return ERL_WASM_ERROR_TRUNCATED;
    }

    /* Decode all elements first */
    erl_term_t **elements = (erl_term_t **)calloc(len, sizeof(erl_term_t *));
    if (!elements) return ERL_WASM_ERROR_NOMEM;

    for (uint32_t i = 0; i < len; i++) {
        erl_wasm_error_t err = decode_term_internal(buf, &elements[i]);
        if (err != ERL_WASM_OK) {
            for (uint32_t j = 0; j < i; j++) {
                erl_free_term(elements[j]);
            }
            free(elements);
            return err;
        }
    }

    /* Decode tail */
    erl_term_t *tail;
    erl_wasm_error_t err = decode_term_internal(buf, &tail);
    if (err != ERL_WASM_OK) {
        for (uint32_t i = 0; i < len; i++) {
            erl_free_term(elements[i]);
        }
        free(elements);
        return err;
    }

    /* Build list from end */
    erl_term_t *list = tail;
    for (int i = (int)len - 1; i >= 0; i--) {
        erl_term_t *cons = erl_cons(elements[i], list);
        if (!cons) {
            for (int j = i; j >= 0; j--) {
                erl_free_term(elements[j]);
            }
            erl_free_term(list);
            free(elements);
            return ERL_WASM_ERROR_NOMEM;
        }
        list = cons;
    }

    free(elements);
    *term_out = list;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_string(buffer_t *buf, erl_term_t **term_out) {
    uint16_t len;
    if (buffer_read_uint16_be(buf, &len) < 0) {
        return ERL_WASM_ERROR_TRUNCATED;
    }

    /* Build list of integers */
    erl_term_t *list = erl_mk_nil();
    if (!list) return ERL_WASM_ERROR_NOMEM;

    /* Read all bytes first */
    uint8_t *bytes = (uint8_t *)malloc(len);
    if (!bytes) {
        erl_free_term(list);
        return ERL_WASM_ERROR_NOMEM;
    }

    if (buffer_read_bytes(buf, bytes, len) < 0) {
        free(bytes);
        erl_free_term(list);
        return ERL_WASM_ERROR_TRUNCATED;
    }

    /* Build list backwards */
    for (int i = (int)len - 1; i >= 0; i--) {
        erl_term_t *elem = erl_mk_integer(bytes[i]);
        if (!elem) {
            free(bytes);
            erl_free_term(list);
            return ERL_WASM_ERROR_NOMEM;
        }
        erl_term_t *cons = erl_cons(elem, list);
        if (!cons) {
            erl_free_term(elem);
            free(bytes);
            erl_free_term(list);
            return ERL_WASM_ERROR_NOMEM;
        }
        list = cons;
    }

    free(bytes);
    *term_out = list;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_map(buffer_t *buf, erl_term_t **term_out) {
    uint32_t size;
    if (buffer_read_uint32_be(buf, &size) < 0) {
        return ERL_WASM_ERROR_TRUNCATED;
    }

    erl_term_t *term = erl_alloc_term();
    if (!term) return ERL_WASM_ERROR_NOMEM;

    term->type = ERL_TERM_MAP;
    term->value.map.size = size;
    term->value.map.entries = (erl_map_entry_t *)calloc(size, sizeof(erl_map_entry_t));
    if (!term->value.map.entries) {
        free(term);
        return ERL_WASM_ERROR_NOMEM;
    }

    for (uint32_t i = 0; i < size; i++) {
        erl_wasm_error_t err = decode_term_internal(buf, &term->value.map.entries[i].key);
        if (err != ERL_WASM_OK) {
            erl_free_term(term);
            return err;
        }
        err = decode_term_internal(buf, &term->value.map.entries[i].value);
        if (err != ERL_WASM_OK) {
            erl_free_term(term);
            return err;
        }
    }

    *term_out = term;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_pid(buffer_t *buf, etf_type_tag_t tag, erl_term_t **term_out) {
    erl_term_t *term = erl_alloc_term();
    if (!term) return ERL_WASM_ERROR_NOMEM;

    term->type = ERL_TERM_PID;

    /* Decode node atom */
    erl_term_t *node_term;
    erl_wasm_error_t err = decode_term_internal(buf, &node_term);
    if (err != ERL_WASM_OK) {
        free(term);
        return err;
    }

    if (!erl_is_atom(node_term)) {
        erl_free_term(node_term);
        free(term);
        return ERL_WASM_ERROR_TYPE;
    }

    term->value.pid.node = node_term->value.atom;
    erl_free_term(node_term);

    if (buffer_read_uint32_be(buf, &term->value.pid.num) < 0 ||
        buffer_read_uint32_be(buf, &term->value.pid.serial) < 0 ||
        buffer_read_uint32_be(buf, &term->value.pid.creation) < 0) {
        free(term);
        return ERL_WASM_ERROR_TRUNCATED;
    }

    *term_out = term;
    return ERL_WASM_OK;
}

static erl_wasm_error_t decode_term_internal(buffer_t *buf, erl_term_t **term_out) {
    uint8_t tag;
    if (buffer_read_byte(buf, &tag) < 0) {
        return ERL_WASM_ERROR_TRUNCATED;
    }

    switch (tag) {
        case ETF_SMALL_INTEGER:
        case ETF_INTEGER:
            return decode_integer(buf, (etf_type_tag_t)tag, term_out);

        case ETF_NEW_FLOAT:
            return decode_float(buf, term_out);

        case ETF_ATOM_UTF8:
        case ETF_SMALL_ATOM_UTF8:
        case ETF_ATOM_DEPRECATED:
        case ETF_SMALL_ATOM_DEPRECATED:
            return decode_atom(buf, (etf_type_tag_t)tag, term_out);

        case ETF_BINARY:
            return decode_binary(buf, term_out);

        case ETF_SMALL_TUPLE:
        case ETF_LARGE_TUPLE:
            return decode_tuple(buf, (etf_type_tag_t)tag, term_out);

        case ETF_NIL:
            return decode_nil(term_out);

        case ETF_LIST:
            return decode_list(buf, term_out);

        case ETF_STRING:
            return decode_string(buf, term_out);

        case ETF_MAP:
            return decode_map(buf, term_out);

        case ETF_NEW_PID:
            return decode_pid(buf, (etf_type_tag_t)tag, term_out);

        default:
            return ERL_WASM_ERROR_TYPE;
    }
}

erl_wasm_error_t erl_decode_term(const uint8_t *data, size_t size, erl_term_t **term_out) {
    if (!data || !term_out || size < 2) {
        return ERL_WASM_ERROR_BADARG;
    }

    /* Check version byte */
    if (data[0] != ETF_VERSION) {
        return ERL_WASM_ERROR_DECODE;
    }

    buffer_t *buf = buffer_wrap(data + 1, size - 1);
    if (!buf) return ERL_WASM_ERROR_NOMEM;

    erl_wasm_error_t err = decode_term_internal(buf, term_out);
    buffer_free_wrap(buf);

    return err;
}

/* ================================================================== */
/*                     ETF Encoding                                    */
/* ================================================================== */

static erl_wasm_error_t encode_term_internal(buffer_t *buf, const erl_term_t *term);

static erl_wasm_error_t encode_atom(buffer_t *buf, const erl_term_t *term) {
    uint16_t len = term->value.atom.length;

    if (len <= 255) {
        if (buffer_write_byte(buf, ETF_SMALL_ATOM_UTF8) < 0) return ERL_WASM_ERROR_ENCODE;
        if (buffer_write_byte(buf, (uint8_t)len) < 0) return ERL_WASM_ERROR_ENCODE;
    } else {
        if (buffer_write_byte(buf, ETF_ATOM_UTF8) < 0) return ERL_WASM_ERROR_ENCODE;
        if (buffer_write_uint16_be(buf, len) < 0) return ERL_WASM_ERROR_ENCODE;
    }

    if (buffer_write_bytes(buf, (const uint8_t *)term->value.atom.name, len) < 0) {
        return ERL_WASM_ERROR_ENCODE;
    }

    return ERL_WASM_OK;
}

static erl_wasm_error_t encode_integer(buffer_t *buf, const erl_term_t *term) {
    int64_t val = term->value.integer;

    if (val >= 0 && val <= 255) {
        if (buffer_write_byte(buf, ETF_SMALL_INTEGER) < 0) return ERL_WASM_ERROR_ENCODE;
        if (buffer_write_byte(buf, (uint8_t)val) < 0) return ERL_WASM_ERROR_ENCODE;
    } else if (val >= -2147483648LL && val <= 2147483647LL) {
        if (buffer_write_byte(buf, ETF_INTEGER) < 0) return ERL_WASM_ERROR_ENCODE;
        if (buffer_write_uint32_be(buf, (uint32_t)val) < 0) return ERL_WASM_ERROR_ENCODE;
    } else {
        /* Need bignum encoding - simplified version */
        return ERL_WASM_ERROR_OVERFLOW;
    }

    return ERL_WASM_OK;
}

static erl_wasm_error_t encode_float(buffer_t *buf, const erl_term_t *term) {
    if (buffer_write_byte(buf, ETF_NEW_FLOAT) < 0) return ERL_WASM_ERROR_ENCODE;

    uint64_t bits;
    memcpy(&bits, &term->value.floating, sizeof(double));

    /* Write big-endian */
    uint8_t bytes[8];
    for (int i = 7; i >= 0; i--) {
        bytes[7 - i] = (bits >> (i * 8)) & 0xFF;
    }

    if (buffer_write_bytes(buf, bytes, 8) < 0) return ERL_WASM_ERROR_ENCODE;
    return ERL_WASM_OK;
}

static erl_wasm_error_t encode_binary(buffer_t *buf, const erl_term_t *term) {
    if (buffer_write_byte(buf, ETF_BINARY) < 0) return ERL_WASM_ERROR_ENCODE;
    if (buffer_write_uint32_be(buf, term->value.binary.size) < 0) return ERL_WASM_ERROR_ENCODE;
    if (buffer_write_bytes(buf, term->value.binary.data, term->value.binary.size) < 0) {
        return ERL_WASM_ERROR_ENCODE;
    }
    return ERL_WASM_OK;
}

static erl_wasm_error_t encode_tuple(buffer_t *buf, const erl_term_t *term) {
    uint32_t arity = term->value.tuple.arity;

    if (arity <= 255) {
        if (buffer_write_byte(buf, ETF_SMALL_TUPLE) < 0) return ERL_WASM_ERROR_ENCODE;
        if (buffer_write_byte(buf, (uint8_t)arity) < 0) return ERL_WASM_ERROR_ENCODE;
    } else {
        if (buffer_write_byte(buf, ETF_LARGE_TUPLE) < 0) return ERL_WASM_ERROR_ENCODE;
        if (buffer_write_uint32_be(buf, arity) < 0) return ERL_WASM_ERROR_ENCODE;
    }

    for (uint32_t i = 0; i < arity; i++) {
        erl_wasm_error_t err = encode_term_internal(buf, term->value.tuple.elements[i]);
        if (err != ERL_WASM_OK) return err;
    }

    return ERL_WASM_OK;
}

static erl_wasm_error_t encode_nil(buffer_t *buf) {
    return buffer_write_byte(buf, ETF_NIL) == 0 ? ERL_WASM_OK : ERL_WASM_ERROR_ENCODE;
}

static erl_wasm_error_t encode_list(buffer_t *buf, const erl_term_t *term) {
    /* Count elements */
    uint32_t len = 0;
    const erl_term_t *curr = term;
    while (curr && curr->type == ERL_TERM_LIST) {
        len++;
        curr = curr->value.list.tail;
    }

    if (buffer_write_byte(buf, ETF_LIST) < 0) return ERL_WASM_ERROR_ENCODE;
    if (buffer_write_uint32_be(buf, len) < 0) return ERL_WASM_ERROR_ENCODE;

    /* Encode elements */
    curr = term;
    while (curr && curr->type == ERL_TERM_LIST) {
        erl_wasm_error_t err = encode_term_internal(buf, curr->value.list.head);
        if (err != ERL_WASM_OK) return err;
        curr = curr->value.list.tail;
    }

    /* Encode tail */
    if (curr) {
        return encode_term_internal(buf, curr);
    } else {
        return encode_nil(buf);
    }
}

static erl_wasm_error_t encode_map(buffer_t *buf, const erl_term_t *term) {
    if (buffer_write_byte(buf, ETF_MAP) < 0) return ERL_WASM_ERROR_ENCODE;
    if (buffer_write_uint32_be(buf, term->value.map.size) < 0) return ERL_WASM_ERROR_ENCODE;

    for (uint32_t i = 0; i < term->value.map.size; i++) {
        erl_wasm_error_t err = encode_term_internal(buf, term->value.map.entries[i].key);
        if (err != ERL_WASM_OK) return err;
        err = encode_term_internal(buf, term->value.map.entries[i].value);
        if (err != ERL_WASM_OK) return err;
    }

    return ERL_WASM_OK;
}

static erl_wasm_error_t encode_pid(buffer_t *buf, const erl_term_t *term) {
    if (buffer_write_byte(buf, ETF_NEW_PID) < 0) return ERL_WASM_ERROR_ENCODE;

    /* Encode node as atom */
    erl_term_t node_term;
    node_term.type = ERL_TERM_ATOM;
    node_term.value.atom = term->value.pid.node;
    erl_wasm_error_t err = encode_atom(buf, &node_term);
    if (err != ERL_WASM_OK) return err;

    if (buffer_write_uint32_be(buf, term->value.pid.num) < 0) return ERL_WASM_ERROR_ENCODE;
    if (buffer_write_uint32_be(buf, term->value.pid.serial) < 0) return ERL_WASM_ERROR_ENCODE;
    if (buffer_write_uint32_be(buf, term->value.pid.creation) < 0) return ERL_WASM_ERROR_ENCODE;

    return ERL_WASM_OK;
}

static erl_wasm_error_t encode_term_internal(buffer_t *buf, const erl_term_t *term) {
    if (!term) return ERL_WASM_ERROR_BADARG;

    switch (term->type) {
        case ERL_TERM_NIL:
            return encode_nil(buf);
        case ERL_TERM_ATOM:
            return encode_atom(buf, term);
        case ERL_TERM_INTEGER:
            return encode_integer(buf, term);
        case ERL_TERM_FLOAT:
            return encode_float(buf, term);
        case ERL_TERM_BINARY:
            return encode_binary(buf, term);
        case ERL_TERM_LIST:
            return encode_list(buf, term);
        case ERL_TERM_TUPLE:
            return encode_tuple(buf, term);
        case ERL_TERM_MAP:
            return encode_map(buf, term);
        case ERL_TERM_PID:
            return encode_pid(buf, term);
        default:
            return ERL_WASM_ERROR_TYPE;
    }
}

erl_wasm_error_t erl_encode_term(const erl_term_t *term, uint8_t **data_out, size_t *size_out) {
    if (!term || !data_out || !size_out) {
        return ERL_WASM_ERROR_BADARG;
    }

    buffer_t *buf = buffer_new(256);
    if (!buf) return ERL_WASM_ERROR_NOMEM;

    /* Write version byte */
    if (buffer_write_byte(buf, ETF_VERSION) < 0) {
        buffer_free(buf);
        return ERL_WASM_ERROR_ENCODE;
    }

    erl_wasm_error_t err = encode_term_internal(buf, term);
    if (err != ERL_WASM_OK) {
        buffer_free(buf);
        return err;
    }

    *data_out = buf->data;
    *size_out = buf->size;
    free(buf);  /* Don't free data, just the struct */

    return ERL_WASM_OK;
}

size_t erl_encoded_size(const erl_term_t *term) {
    uint8_t *data;
    size_t size;
    if (erl_encode_term(term, &data, &size) == ERL_WASM_OK) {
        free(data);
        return size;
    }
    return 0;
}

/* ================================================================== */
/*               gen_wasmserver Result Builders                        */
/* ================================================================== */

erl_wasm_error_t wasm_init_ok(erl_term_t *state, uint8_t **data_out, size_t *size_out) {
    erl_term_t *ok = erl_mk_atom("ok");
    if (!ok) return ERL_WASM_ERROR_NOMEM;

    erl_term_t *result = erl_mk_tuple2(ok, state);
    if (!result) {
        erl_free_term(ok);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    /* Don't free state, it's borrowed */
    result->value.tuple.elements[1] = NULL;
    result->value.tuple.arity = 1;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_init_ok_timeout(erl_term_t *state, uint32_t timeout_ms,
                                      uint8_t **data_out, size_t *size_out) {
    erl_term_t *ok = erl_mk_atom("ok");
    erl_term_t *timeout = erl_mk_integer(timeout_ms);
    if (!ok || !timeout) {
        erl_free_term(ok);
        erl_free_term(timeout);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_term_t *result = erl_mk_tuple3(ok, state, timeout);
    if (!result) {
        erl_free_term(ok);
        erl_free_term(timeout);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.arity = 2;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_init_ok_hibernate(erl_term_t *state,
                                        uint8_t **data_out, size_t *size_out) {
    erl_term_t *ok = erl_mk_atom("ok");
    erl_term_t *hibernate = erl_mk_atom("hibernate");
    if (!ok || !hibernate) {
        erl_free_term(ok);
        erl_free_term(hibernate);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_term_t *result = erl_mk_tuple3(ok, state, hibernate);
    if (!result) {
        erl_free_term(ok);
        erl_free_term(hibernate);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.arity = 2;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_init_stop(erl_term_t *reason, uint8_t **data_out, size_t *size_out) {
    erl_term_t *stop = erl_mk_atom("stop");
    if (!stop) return ERL_WASM_ERROR_NOMEM;

    erl_term_t *result = erl_mk_tuple2(stop, reason);
    if (!result) {
        erl_free_term(stop);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.arity = 1;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_init_ignore(uint8_t **data_out, size_t *size_out) {
    erl_term_t *ignore = erl_mk_atom("ignore");
    if (!ignore) return ERL_WASM_ERROR_NOMEM;

    erl_wasm_error_t err = erl_encode_term(ignore, data_out, size_out);
    erl_free_term(ignore);

    return err;
}

erl_wasm_error_t wasm_call_reply(erl_term_t *reply, erl_term_t *state,
                                 uint8_t **data_out, size_t *size_out) {
    erl_term_t *reply_atom = erl_mk_atom("reply");
    if (!reply_atom) return ERL_WASM_ERROR_NOMEM;

    erl_term_t *result = erl_mk_tuple3(reply_atom, reply, state);
    if (!result) {
        erl_free_term(reply_atom);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.elements[2] = NULL;
    result->value.tuple.arity = 1;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_call_reply_timeout(erl_term_t *reply, erl_term_t *state,
                                         uint32_t timeout_ms,
                                         uint8_t **data_out, size_t *size_out) {
    erl_term_t *reply_atom = erl_mk_atom("reply");
    erl_term_t *timeout = erl_mk_integer(timeout_ms);
    if (!reply_atom || !timeout) {
        erl_free_term(reply_atom);
        erl_free_term(timeout);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_term_t *result = erl_mk_tuple4(reply_atom, reply, state, timeout);
    if (!result) {
        erl_free_term(reply_atom);
        erl_free_term(timeout);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.elements[2] = NULL;
    result->value.tuple.arity = 2;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_call_reply_hibernate(erl_term_t *reply, erl_term_t *state,
                                           uint8_t **data_out, size_t *size_out) {
    erl_term_t *reply_atom = erl_mk_atom("reply");
    erl_term_t *hibernate = erl_mk_atom("hibernate");
    if (!reply_atom || !hibernate) {
        erl_free_term(reply_atom);
        erl_free_term(hibernate);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_term_t *result = erl_mk_tuple4(reply_atom, reply, state, hibernate);
    if (!result) {
        erl_free_term(reply_atom);
        erl_free_term(hibernate);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.elements[2] = NULL;
    result->value.tuple.arity = 2;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_call_noreply(erl_term_t *state, uint8_t **data_out, size_t *size_out) {
    erl_term_t *noreply = erl_mk_atom("noreply");
    if (!noreply) return ERL_WASM_ERROR_NOMEM;

    erl_term_t *result = erl_mk_tuple2(noreply, state);
    if (!result) {
        erl_free_term(noreply);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.arity = 1;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_call_stop_reply(erl_term_t *reason, erl_term_t *reply,
                                      erl_term_t *state,
                                      uint8_t **data_out, size_t *size_out) {
    erl_term_t *stop = erl_mk_atom("stop");
    if (!stop) return ERL_WASM_ERROR_NOMEM;

    erl_term_t *result = erl_mk_tuple4(stop, reason, reply, state);
    if (!result) {
        erl_free_term(stop);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.elements[2] = NULL;
    result->value.tuple.elements[3] = NULL;
    result->value.tuple.arity = 1;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_call_stop(erl_term_t *reason, erl_term_t *state,
                                uint8_t **data_out, size_t *size_out) {
    erl_term_t *stop = erl_mk_atom("stop");
    if (!stop) return ERL_WASM_ERROR_NOMEM;

    erl_term_t *result = erl_mk_tuple3(stop, reason, state);
    if (!result) {
        erl_free_term(stop);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.elements[2] = NULL;
    result->value.tuple.arity = 1;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_cast_noreply(erl_term_t *state, uint8_t **data_out, size_t *size_out) {
    return wasm_call_noreply(state, data_out, size_out);
}

erl_wasm_error_t wasm_cast_noreply_timeout(erl_term_t *state, uint32_t timeout_ms,
                                           uint8_t **data_out, size_t *size_out) {
    erl_term_t *noreply = erl_mk_atom("noreply");
    erl_term_t *timeout = erl_mk_integer(timeout_ms);
    if (!noreply || !timeout) {
        erl_free_term(noreply);
        erl_free_term(timeout);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_term_t *result = erl_mk_tuple3(noreply, state, timeout);
    if (!result) {
        erl_free_term(noreply);
        erl_free_term(timeout);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.arity = 2;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_cast_noreply_hibernate(erl_term_t *state,
                                             uint8_t **data_out, size_t *size_out) {
    erl_term_t *noreply = erl_mk_atom("noreply");
    erl_term_t *hibernate = erl_mk_atom("hibernate");
    if (!noreply || !hibernate) {
        erl_free_term(noreply);
        erl_free_term(hibernate);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_term_t *result = erl_mk_tuple3(noreply, state, hibernate);
    if (!result) {
        erl_free_term(noreply);
        erl_free_term(hibernate);
        return ERL_WASM_ERROR_NOMEM;
    }

    erl_wasm_error_t err = erl_encode_term(result, data_out, size_out);

    result->value.tuple.elements[1] = NULL;
    result->value.tuple.arity = 2;
    erl_free_term(result);

    return err;
}

erl_wasm_error_t wasm_cast_stop(erl_term_t *reason, erl_term_t *state,
                                uint8_t **data_out, size_t *size_out) {
    return wasm_call_stop(reason, state, data_out, size_out);
}

/* ================================================================== */
/*                     Utility Functions                               */
/* ================================================================== */

const char *erl_wasm_strerror(erl_wasm_error_t error) {
    switch (error) {
        case ERL_WASM_OK:            return "Success";
        case ERL_WASM_ERROR:         return "Generic error";
        case ERL_WASM_ERROR_NOMEM:   return "Out of memory";
        case ERL_WASM_ERROR_BADARG:  return "Bad argument";
        case ERL_WASM_ERROR_DECODE:  return "Decode error";
        case ERL_WASM_ERROR_ENCODE:  return "Encode error";
        case ERL_WASM_ERROR_TYPE:    return "Type error";
        case ERL_WASM_ERROR_OVERFLOW: return "Overflow";
        case ERL_WASM_ERROR_TRUNCATED: return "Data truncated";
        default:                      return "Unknown error";
    }
}

erl_term_t *erl_copy_term(const erl_term_t *term) {
    if (!term) return NULL;

    erl_term_t *copy = erl_alloc_term();
    if (!copy) return NULL;

    copy->type = term->type;

    switch (term->type) {
        case ERL_TERM_NIL:
            break;
        case ERL_TERM_ATOM:
            copy->value.atom = term->value.atom;
            break;
        case ERL_TERM_INTEGER:
            copy->value.integer = term->value.integer;
            break;
        case ERL_TERM_FLOAT:
            copy->value.floating = term->value.floating;
            break;
        case ERL_TERM_BINARY:
            copy->value.binary.size = term->value.binary.size;
            copy->value.binary.data = (uint8_t *)malloc(term->value.binary.size);
            if (!copy->value.binary.data) {
                free(copy);
                return NULL;
            }
            memcpy(copy->value.binary.data, term->value.binary.data, term->value.binary.size);
            break;
        case ERL_TERM_LIST:
            copy->value.list.head = erl_copy_term(term->value.list.head);
            copy->value.list.tail = erl_copy_term(term->value.list.tail);
            if ((term->value.list.head && !copy->value.list.head) ||
                (term->value.list.tail && !copy->value.list.tail)) {
                erl_free_term(copy);
                return NULL;
            }
            break;
        case ERL_TERM_TUPLE:
            copy->value.tuple.arity = term->value.tuple.arity;
            copy->value.tuple.elements = (erl_term_t **)calloc(term->value.tuple.arity, sizeof(erl_term_t *));
            if (!copy->value.tuple.elements) {
                free(copy);
                return NULL;
            }
            for (uint32_t i = 0; i < term->value.tuple.arity; i++) {
                copy->value.tuple.elements[i] = erl_copy_term(term->value.tuple.elements[i]);
                if (!copy->value.tuple.elements[i]) {
                    erl_free_term(copy);
                    return NULL;
                }
            }
            break;
        case ERL_TERM_MAP:
            copy->value.map.size = term->value.map.size;
            copy->value.map.entries = (erl_map_entry_t *)calloc(term->value.map.size, sizeof(erl_map_entry_t));
            if (!copy->value.map.entries) {
                free(copy);
                return NULL;
            }
            for (uint32_t i = 0; i < term->value.map.size; i++) {
                copy->value.map.entries[i].key = erl_copy_term(term->value.map.entries[i].key);
                copy->value.map.entries[i].value = erl_copy_term(term->value.map.entries[i].value);
                if (!copy->value.map.entries[i].key || !copy->value.map.entries[i].value) {
                    erl_free_term(copy);
                    return NULL;
                }
            }
            break;
        case ERL_TERM_PID:
            copy->value.pid = term->value.pid;
            break;
        case ERL_TERM_REF:
            copy->value.ref = term->value.ref;
            break;
        case ERL_TERM_PORT:
            copy->value.port = term->value.port;
            break;
        default:
            free(copy);
            return NULL;
    }

    return copy;
}

bool erl_terms_equal(const erl_term_t *a, const erl_term_t *b) {
    if (a == b) return true;
    if (!a || !b) return false;
    if (a->type != b->type) return false;

    switch (a->type) {
        case ERL_TERM_NIL:
            return true;
        case ERL_TERM_ATOM:
            return a->value.atom.length == b->value.atom.length &&
                   memcmp(a->value.atom.name, b->value.atom.name, a->value.atom.length) == 0;
        case ERL_TERM_INTEGER:
            return a->value.integer == b->value.integer;
        case ERL_TERM_FLOAT:
            return a->value.floating == b->value.floating;
        case ERL_TERM_BINARY:
            return a->value.binary.size == b->value.binary.size &&
                   memcmp(a->value.binary.data, b->value.binary.data, a->value.binary.size) == 0;
        case ERL_TERM_LIST:
            return erl_terms_equal(a->value.list.head, b->value.list.head) &&
                   erl_terms_equal(a->value.list.tail, b->value.list.tail);
        case ERL_TERM_TUPLE:
            if (a->value.tuple.arity != b->value.tuple.arity) return false;
            for (uint32_t i = 0; i < a->value.tuple.arity; i++) {
                if (!erl_terms_equal(a->value.tuple.elements[i], b->value.tuple.elements[i])) {
                    return false;
                }
            }
            return true;
        case ERL_TERM_MAP:
            if (a->value.map.size != b->value.map.size) return false;
            /* Maps require more complex comparison */
            for (uint32_t i = 0; i < a->value.map.size; i++) {
                erl_term_t *val = erl_map_get(b, a->value.map.entries[i].key);
                if (!val || !erl_terms_equal(a->value.map.entries[i].value, val)) {
                    return false;
                }
            }
            return true;
        case ERL_TERM_PID:
            return memcmp(&a->value.pid, &b->value.pid, sizeof(erl_pid_t)) == 0;
        default:
            return false;
    }
}

int erl_term_to_string(const erl_term_t *term, char *buf, size_t buf_size) {
    if (!term || !buf || buf_size == 0) return -1;

    switch (term->type) {
        case ERL_TERM_NIL:
            return snprintf(buf, buf_size, "[]");
        case ERL_TERM_ATOM:
            return snprintf(buf, buf_size, "'%s'", term->value.atom.name);
        case ERL_TERM_INTEGER:
            return snprintf(buf, buf_size, "%lld", (long long)term->value.integer);
        case ERL_TERM_FLOAT:
            return snprintf(buf, buf_size, "%g", term->value.floating);
        case ERL_TERM_BINARY:
            return snprintf(buf, buf_size, "<<...%u bytes...>>", term->value.binary.size);
        case ERL_TERM_TUPLE:
            return snprintf(buf, buf_size, "{...%u elements...}", term->value.tuple.arity);
        case ERL_TERM_LIST:
            return snprintf(buf, buf_size, "[...%u elements...]", erl_list_length(term));
        case ERL_TERM_MAP:
            return snprintf(buf, buf_size, "#{...%u pairs...}", term->value.map.size);
        case ERL_TERM_PID:
            return snprintf(buf, buf_size, "<pid>");
        default:
            return snprintf(buf, buf_size, "<unknown>");
    }
}

/* ================================================================== */
/*                   WASM Memory Management                            */
/* ================================================================== */

uint8_t *wasm_alloc(uint32_t size) {
    return (uint8_t *)malloc(size);
}

void wasm_free(uint8_t *ptr) {
    free(ptr);
}
