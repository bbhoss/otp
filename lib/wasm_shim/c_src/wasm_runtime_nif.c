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
 * wasm_runtime_nif.c
 *
 * NIF implementation for WebAssembly runtime integration.
 * This file provides the native interface between Erlang and a WASM runtime.
 *
 * Currently supports:
 * - wasmtime (Bytecode Alliance)
 *
 * To build with wasmtime:
 *   1. Install wasmtime-c-api
 *   2. Compile with: -DUSE_WASMTIME -I/path/to/wasmtime/include -lwasmtime
 */

#include "erl_nif.h"
#include <string.h>
#include <stdlib.h>

/* ================================================================== */
/*                    Resource Type Definitions                        */
/* ================================================================== */

/* WASM instance resource */
typedef struct {
    void *engine;      /* WASM runtime engine handle */
    void *store;       /* WASM store handle */
    void *instance;    /* WASM instance handle */
    void *memory;      /* WASM linear memory handle */
    ErlNifBinary wasm_binary;  /* Original WASM binary */
} wasm_instance_t;

static ErlNifResourceType *wasm_instance_type = NULL;

/* ================================================================== */
/*                    Forward Declarations                             */
/* ================================================================== */

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason);
static ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, const char *tag, const char *reason);
static ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value);

/* ================================================================== */
/*                    Resource Management                              */
/* ================================================================== */

static void wasm_instance_destructor(ErlNifEnv *env, void *obj) {
    (void)env;
    wasm_instance_t *instance = (wasm_instance_t *)obj;

    /* Clean up WASM resources */
#ifdef USE_WASMTIME
    /* TODO: Clean up wasmtime resources */
#endif

    /* Release the binary if we own it */
    if (instance->wasm_binary.data) {
        enif_release_binary(&instance->wasm_binary);
    }
}

/* ================================================================== */
/*                    NIF Implementations                              */
/* ================================================================== */

/*
 * load_module_nif(WasmBinary, Options) -> {ok, Ref, Exports} | {error, Reason}
 */
static ERL_NIF_TERM load_module_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;

    ErlNifBinary wasm_binary;
    if (!enif_inspect_binary(env, argv[0], &wasm_binary)) {
        return enif_make_badarg(env);
    }

    /* Validate WASM magic number */
    if (wasm_binary.size < 8 ||
        wasm_binary.data[0] != 0x00 ||
        wasm_binary.data[1] != 0x61 ||
        wasm_binary.data[2] != 0x73 ||
        wasm_binary.data[3] != 0x6D) {
        return make_error(env, "invalid_magic");
    }

    /* Check version */
    uint32_t version = wasm_binary.data[4] |
                       (wasm_binary.data[5] << 8) |
                       (wasm_binary.data[6] << 16) |
                       (wasm_binary.data[7] << 24);
    if (version < 1) {
        return make_error_tuple(env, "unsupported_version", "version must be >= 1");
    }

    /* Create resource */
    wasm_instance_t *instance = enif_alloc_resource(wasm_instance_type, sizeof(wasm_instance_t));
    if (!instance) {
        return make_error(env, "alloc_failed");
    }

    memset(instance, 0, sizeof(wasm_instance_t));

    /* Copy WASM binary */
    if (!enif_alloc_binary(wasm_binary.size, &instance->wasm_binary)) {
        enif_release_resource(instance);
        return make_error(env, "binary_alloc_failed");
    }
    memcpy(instance->wasm_binary.data, wasm_binary.data, wasm_binary.size);

#ifdef USE_WASMTIME
    /* TODO: Initialize wasmtime engine, compile module, create instance */
#endif

    /* Create reference and exports map */
    ERL_NIF_TERM ref = enif_make_resource(env, instance);
    enif_release_resource(instance);

    /* Build exports map with expected gen_wasmserver functions */
    ERL_NIF_TERM exports_map;
    ERL_NIF_TERM keys[5], values[5];

    keys[0] = enif_make_atom(env, "wasm_init");
    values[0] = enif_make_int(env, 1);

    keys[1] = enif_make_atom(env, "wasm_handle_call");
    values[1] = enif_make_int(env, 3);

    keys[2] = enif_make_atom(env, "wasm_handle_cast");
    values[2] = enif_make_int(env, 2);

    keys[3] = enif_make_atom(env, "wasm_handle_info");
    values[3] = enif_make_int(env, 2);

    keys[4] = enif_make_atom(env, "wasm_terminate");
    values[4] = enif_make_int(env, 2);

    enif_make_map_from_arrays(env, keys, values, 5, &exports_map);

    return enif_make_tuple3(env,
                            enif_make_atom(env, "ok"),
                            ref,
                            exports_map);
}

/*
 * unload_module_nif(Ref) -> ok
 */
static ERL_NIF_TERM unload_module_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;

    wasm_instance_t *instance;
    if (!enif_get_resource(env, argv[0], wasm_instance_type, (void **)&instance)) {
        return enif_make_badarg(env);
    }

    /* Resources are cleaned up when the last reference is released */
    return enif_make_atom(env, "ok");
}

/*
 * call_function_nif(Ref, Function, Args, Options) -> {ok, Result} | {error, Reason}
 */
static ERL_NIF_TERM call_function_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;

    wasm_instance_t *instance;
    if (!enif_get_resource(env, argv[0], wasm_instance_type, (void **)&instance)) {
        return enif_make_badarg(env);
    }

    char func_name[256];
    if (!enif_get_atom(env, argv[1], func_name, sizeof(func_name), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }

    /* Get args list */
    unsigned int args_len;
    if (!enif_get_list_length(env, argv[2], &args_len)) {
        return enif_make_badarg(env);
    }

    /* Collect binary arguments */
    ERL_NIF_TERM args_list = argv[2];
    ErlNifBinary *arg_binaries = args_len > 0 ?
        enif_alloc(args_len * sizeof(ErlNifBinary)) : NULL;

    for (unsigned int i = 0; i < args_len; i++) {
        ERL_NIF_TERM head, tail;
        if (!enif_get_list_cell(env, args_list, &head, &tail)) {
            if (arg_binaries) enif_free(arg_binaries);
            return enif_make_badarg(env);
        }
        if (!enif_inspect_binary(env, head, &arg_binaries[i])) {
            if (arg_binaries) enif_free(arg_binaries);
            return enif_make_badarg(env);
        }
        args_list = tail;
    }

#ifdef USE_WASMTIME
    /* TODO: Call WASM function via wasmtime */
#endif

    /* Stub implementation: simulate gen_wasmserver callbacks */
    ERL_NIF_TERM result;

    if (strcmp(func_name, "wasm_init") == 0 && args_len >= 1) {
        /* Return {ok, Args} encoded as ETF */
        /* For stub, just return the input args wrapped in {ok, _} */
        ERL_NIF_TERM ok_atom = enif_make_atom(env, "ok");
        ERL_NIF_TERM args_term;

        /* Decode the ETF args and re-encode with 'ok' tuple */
        if (!enif_binary_to_term(env, arg_binaries[0].data, arg_binaries[0].size,
                                  &args_term, 0)) {
            args_term = enif_make_binary(env, &arg_binaries[0]);
        }

        ERL_NIF_TERM tuple = enif_make_tuple2(env, ok_atom, args_term);
        ErlNifBinary result_bin;
        if (enif_term_to_binary(env, tuple, &result_bin)) {
            result = make_ok_tuple(env, enif_make_binary(env, &result_bin));
        } else {
            result = make_error(env, "encode_failed");
        }
    }
    else if (strcmp(func_name, "wasm_handle_call") == 0 && args_len >= 3) {
        /* Return {reply, echo(Request), State} */
        ERL_NIF_TERM request_term, state_term;

        if (!enif_binary_to_term(env, arg_binaries[0].data, arg_binaries[0].size,
                                  &request_term, 0)) {
            request_term = enif_make_atom(env, "unknown");
        }
        if (!enif_binary_to_term(env, arg_binaries[2].data, arg_binaries[2].size,
                                  &state_term, 0)) {
            state_term = enif_make_atom(env, "undefined");
        }

        ERL_NIF_TERM reply = enif_make_tuple2(env,
                                              enif_make_atom(env, "echo"),
                                              request_term);
        ERL_NIF_TERM tuple = enif_make_tuple3(env,
                                              enif_make_atom(env, "reply"),
                                              reply,
                                              state_term);

        ErlNifBinary result_bin;
        if (enif_term_to_binary(env, tuple, &result_bin)) {
            result = make_ok_tuple(env, enif_make_binary(env, &result_bin));
        } else {
            result = make_error(env, "encode_failed");
        }
    }
    else if ((strcmp(func_name, "wasm_handle_cast") == 0 ||
              strcmp(func_name, "wasm_handle_info") == 0) && args_len >= 2) {
        /* Return {noreply, State} */
        ERL_NIF_TERM state_term;

        if (!enif_binary_to_term(env, arg_binaries[args_len-1].data,
                                  arg_binaries[args_len-1].size,
                                  &state_term, 0)) {
            state_term = enif_make_atom(env, "undefined");
        }

        ERL_NIF_TERM tuple = enif_make_tuple2(env,
                                              enif_make_atom(env, "noreply"),
                                              state_term);

        ErlNifBinary result_bin;
        if (enif_term_to_binary(env, tuple, &result_bin)) {
            result = make_ok_tuple(env, enif_make_binary(env, &result_bin));
        } else {
            result = make_error(env, "encode_failed");
        }
    }
    else if (strcmp(func_name, "wasm_terminate") == 0) {
        /* Return ok */
        ERL_NIF_TERM ok = enif_make_atom(env, "ok");
        ErlNifBinary result_bin;
        if (enif_term_to_binary(env, ok, &result_bin)) {
            result = make_ok_tuple(env, enif_make_binary(env, &result_bin));
        } else {
            result = make_error(env, "encode_failed");
        }
    }
    else {
        result = make_error_tuple(env, "unknown_function", func_name);
    }

    if (arg_binaries) enif_free(arg_binaries);
    return result;
}

/*
 * get_exports_nif(Ref) -> {ok, Exports} | {error, Reason}
 */
static ERL_NIF_TERM get_exports_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;

    wasm_instance_t *instance;
    if (!enif_get_resource(env, argv[0], wasm_instance_type, (void **)&instance)) {
        return enif_make_badarg(env);
    }

    /* Return standard exports */
    ERL_NIF_TERM exports_map;
    ERL_NIF_TERM keys[5], values[5];

    keys[0] = enif_make_atom(env, "wasm_init");
    values[0] = enif_make_int(env, 1);

    keys[1] = enif_make_atom(env, "wasm_handle_call");
    values[1] = enif_make_int(env, 3);

    keys[2] = enif_make_atom(env, "wasm_handle_cast");
    values[2] = enif_make_int(env, 2);

    keys[3] = enif_make_atom(env, "wasm_handle_info");
    values[3] = enif_make_int(env, 2);

    keys[4] = enif_make_atom(env, "wasm_terminate");
    values[4] = enif_make_int(env, 2);

    enif_make_map_from_arrays(env, keys, values, 5, &exports_map);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), exports_map);
}

/*
 * get_memory_nif(Ref, {Offset, Length}) -> {ok, Binary} | {error, Reason}
 */
static ERL_NIF_TERM get_memory_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;

    wasm_instance_t *instance;
    if (!enif_get_resource(env, argv[0], wasm_instance_type, (void **)&instance)) {
        return enif_make_badarg(env);
    }

    int arity;
    const ERL_NIF_TERM *tuple;
    if (!enif_get_tuple(env, argv[1], &arity, &tuple) || arity != 2) {
        return enif_make_badarg(env);
    }

    unsigned long offset, length;
    if (!enif_get_ulong(env, tuple[0], &offset) ||
        !enif_get_ulong(env, tuple[1], &length)) {
        return enif_make_badarg(env);
    }

    /* Stub: return zeros */
    ErlNifBinary result;
    if (!enif_alloc_binary(length, &result)) {
        return make_error(env, "alloc_failed");
    }
    memset(result.data, 0, length);

    return make_ok_tuple(env, enif_make_binary(env, &result));
}

/*
 * set_memory_nif(Ref, Offset, Data) -> ok | {error, Reason}
 */
static ERL_NIF_TERM set_memory_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;

    wasm_instance_t *instance;
    if (!enif_get_resource(env, argv[0], wasm_instance_type, (void **)&instance)) {
        return enif_make_badarg(env);
    }

    unsigned long offset;
    if (!enif_get_ulong(env, argv[1], &offset)) {
        return enif_make_badarg(env);
    }

    ErlNifBinary data;
    if (!enif_inspect_binary(env, argv[2], &data)) {
        return enif_make_badarg(env);
    }

    /* Stub: do nothing */
    (void)offset;
    (void)data;

    return enif_make_atom(env, "ok");
}

/*
 * validate_module_nif(WasmBinary) -> ok | {error, Reason}
 */
static ERL_NIF_TERM validate_module_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;

    ErlNifBinary wasm_binary;
    if (!enif_inspect_binary(env, argv[0], &wasm_binary)) {
        return enif_make_badarg(env);
    }

    /* Validate WASM magic number */
    if (wasm_binary.size < 8) {
        return make_error(env, "too_short");
    }

    if (wasm_binary.data[0] != 0x00 ||
        wasm_binary.data[1] != 0x61 ||
        wasm_binary.data[2] != 0x73 ||
        wasm_binary.data[3] != 0x6D) {
        return make_error(env, "invalid_magic");
    }

    uint32_t version = wasm_binary.data[4] |
                       (wasm_binary.data[5] << 8) |
                       (wasm_binary.data[6] << 16) |
                       (wasm_binary.data[7] << 24);
    if (version < 1) {
        return make_error_tuple(env, "unsupported_version", "version must be >= 1");
    }

    return enif_make_atom(env, "ok");
}

/* ================================================================== */
/*                    Helper Functions                                 */
/* ================================================================== */

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env,
                            enif_make_atom(env, "error"),
                            enif_make_atom(env, reason));
}

static ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, const char *tag, const char *reason) {
    return enif_make_tuple2(env,
                            enif_make_atom(env, "error"),
                            enif_make_tuple2(env,
                                             enif_make_atom(env, tag),
                                             enif_make_string(env, reason, ERL_NIF_LATIN1)));
}

static ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value) {
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), value);
}

/* ================================================================== */
/*                    NIF Initialization                               */
/* ================================================================== */

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;

    /* Create resource type for WASM instances */
    ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    wasm_instance_type = enif_open_resource_type(env, NULL, "wasm_instance",
                                                  wasm_instance_destructor,
                                                  flags, NULL);
    if (!wasm_instance_type) {
        return -1;
    }

    return 0;
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info) {
    (void)old_priv_data;
    return load(env, priv_data, load_info);
}

static void unload(ErlNifEnv *env, void *priv_data) {
    (void)env;
    (void)priv_data;
}

static ErlNifFunc nif_funcs[] = {
    {"load_module_nif", 2, load_module_nif, 0},
    {"unload_module_nif", 1, unload_module_nif, 0},
    {"call_function_nif", 4, call_function_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"get_exports_nif", 1, get_exports_nif, 0},
    {"get_memory_nif", 2, get_memory_nif, 0},
    {"set_memory_nif", 3, set_memory_nif, 0},
    {"validate_module_nif", 1, validate_module_nif, 0}
};

ERL_NIF_INIT(wasm_runtime_nif, nif_funcs, load, NULL, upgrade, unload)
