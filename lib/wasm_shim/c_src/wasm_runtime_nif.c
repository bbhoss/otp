/*
 * wasm_runtime_nif.c - NIF for WASM execution using wasmtime
 */

#include "erl_nif.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <wasm.h>
#include <wasmtime.h>
#include <wasi.h>

/* Resource type for WASM instances */
static ErlNifResourceType *WASM_INSTANCE_RESOURCE = NULL;

/* Structure to hold a WASM instance */
typedef struct {
    wasm_engine_t *engine;
    wasmtime_store_t *store;
    wasmtime_module_t *module;
    wasmtime_instance_t instance;
    wasmtime_memory_t memory;
    int has_memory;
    int instance_valid;
} erl_wasm_instance_t;

/* Atoms - cached for performance */
static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_ERROR;
static ERL_NIF_TERM ATOM_UNDEFINED;
static ERL_NIF_TERM ATOM_REPLY;
static ERL_NIF_TERM ATOM_NOREPLY;

/* Helper to make atom */
static ERL_NIF_TERM make_atom(ErlNifEnv *env, const char *name) {
    ERL_NIF_TERM atom;
    if (enif_make_existing_atom(env, name, &atom, ERL_NIF_LATIN1)) {
        return atom;
    }
    return enif_make_atom(env, name);
}

/* Helper to make error tuple */
static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env, ATOM_ERROR, make_atom(env, reason));
}

/* Helper to make error from wasmtime error */
static ERL_NIF_TERM make_wasmtime_error(ErlNifEnv *env, wasmtime_error_t *error) {
    wasm_name_t message;
    wasmtime_error_message(error, &message);
    ERL_NIF_TERM reason = enif_make_string_len(env, message.data, message.size, ERL_NIF_LATIN1);
    wasm_name_delete(&message);
    wasmtime_error_delete(error);
    return enif_make_tuple2(env, ATOM_ERROR, reason);
}

/* Destructor for WASM instance resource */
static void wasm_instance_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    erl_wasm_instance_t *inst = (erl_wasm_instance_t *)obj;
    if (inst->store) {
        wasmtime_store_delete(inst->store);
        inst->store = NULL;
    }
    if (inst->module) {
        wasmtime_module_delete(inst->module);
        inst->module = NULL;
    }
    if (inst->engine) {
        wasm_engine_delete(inst->engine);
        inst->engine = NULL;
    }
}

/* NIF: load_module_nif(WasmBinary, Options) -> {ok, Ref, Exports} | {error, Reason} */
static ERL_NIF_TERM load_module_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary wasm_binary;
    wasmtime_error_t *error = NULL;

    if (!enif_inspect_binary(env, argv[0], &wasm_binary)) {
        return enif_make_badarg(env);
    }

    /* Create engine */
    wasm_engine_t *engine = wasm_engine_new();
    if (!engine) {
        return make_error(env, "failed_to_create_engine");
    }

    /* Create store */
    wasmtime_store_t *store = wasmtime_store_new(engine, NULL, NULL);
    if (!store) {
        wasm_engine_delete(engine);
        return make_error(env, "failed_to_create_store");
    }

    wasmtime_context_t *context = wasmtime_store_context(store);

    /* Compile module */
    wasmtime_module_t *module = NULL;
    error = wasmtime_module_new(engine, wasm_binary.data, wasm_binary.size, &module);
    if (error) {
        wasmtime_store_delete(store);
        wasm_engine_delete(engine);
        return make_wasmtime_error(env, error);
    }

    /* Set up WASI config */
    wasi_config_t *wasi_config = wasi_config_new();
    wasi_config_inherit_stdout(wasi_config);
    wasi_config_inherit_stderr(wasi_config);

    /* Add WASI to the store */
    error = wasmtime_context_set_wasi(context, wasi_config);
    if (error) {
        wasmtime_module_delete(module);
        wasmtime_store_delete(store);
        wasm_engine_delete(engine);
        return make_wasmtime_error(env, error);
    }

    /* Create linker for WASI */
    wasmtime_linker_t *linker = wasmtime_linker_new(engine);
    error = wasmtime_linker_define_wasi(linker);
    if (error) {
        wasmtime_linker_delete(linker);
        wasmtime_module_delete(module);
        wasmtime_store_delete(store);
        wasm_engine_delete(engine);
        return make_wasmtime_error(env, error);
    }

    /* Instantiate module with WASI imports */
    wasmtime_instance_t instance;
    wasm_trap_t *trap = NULL;
    error = wasmtime_linker_instantiate(linker, context, module, &instance, &trap);
    wasmtime_linker_delete(linker);
    if (error || trap) {
        if (trap) wasm_trap_delete(trap);
        wasmtime_module_delete(module);
        wasmtime_store_delete(store);
        wasm_engine_delete(engine);
        if (error) return make_wasmtime_error(env, error);
        return make_error(env, "instantiation_trapped");
    }

    /* Create resource */
    erl_wasm_instance_t *inst = enif_alloc_resource(WASM_INSTANCE_RESOURCE, sizeof(erl_wasm_instance_t));
    memset(inst, 0, sizeof(erl_wasm_instance_t));
    inst->engine = engine;
    inst->store = store;
    inst->module = module;
    inst->instance = instance;
    inst->instance_valid = 1;
    inst->has_memory = 0;

    /* Try to get memory export */
    wasmtime_extern_t memory_extern;
    if (wasmtime_instance_export_get(context, &instance, "memory", 6, &memory_extern)) {
        if (memory_extern.kind == WASMTIME_EXTERN_MEMORY) {
            inst->memory = memory_extern.of.memory;
            inst->has_memory = 1;
        }
    }

    /* Build exports map */
    wasm_exporttype_vec_t export_types;
    wasmtime_module_exports(module, &export_types);

    ERL_NIF_TERM keys[64], values[64];
    int idx = 0;

    for (size_t i = 0; i < export_types.size && idx < 64; i++) {
        const wasm_name_t *name = wasm_exporttype_name(export_types.data[i]);
        const wasm_externtype_t *type = wasm_exporttype_type(export_types.data[i]);

        if (wasm_externtype_kind(type) == WASM_EXTERN_FUNC) {
            const wasm_functype_t *func_type = wasm_externtype_as_functype_const(type);
            const wasm_valtype_vec_t *params = wasm_functype_params(func_type);

            keys[idx] = enif_make_atom_len(env, name->data, name->size);
            values[idx] = enif_make_int(env, (int)params->size);
            idx++;
        }
    }
    wasm_exporttype_vec_delete(&export_types);

    ERL_NIF_TERM exports_map;
    enif_make_map_from_arrays(env, keys, values, idx, &exports_map);

    /* Return {ok, Ref, Exports} */
    ERL_NIF_TERM ref = enif_make_resource(env, inst);
    enif_release_resource(inst);

    return enif_make_tuple3(env, ATOM_OK, ref, exports_map);
}

/* NIF: unload_module_nif(Ref) -> ok */
static ERL_NIF_TERM unload_module_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    erl_wasm_instance_t *inst;
    if (!enif_get_resource(env, argv[0], WASM_INSTANCE_RESOURCE, (void **)&inst)) {
        return enif_make_badarg(env);
    }
    inst->instance_valid = 0;
    return ATOM_OK;
}

/* NIF: call_function_nif(Ref, FuncName, Args, Options) -> {ok, Result} | {error, Reason} */
static ERL_NIF_TERM call_function_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    erl_wasm_instance_t *inst;
    char func_name[256];

    if (!enif_get_resource(env, argv[0], WASM_INSTANCE_RESOURCE, (void **)&inst)) {
        return enif_make_badarg(env);
    }

    if (!inst->instance_valid) {
        return make_error(env, "instance_unloaded");
    }

    if (!enif_get_atom(env, argv[1], func_name, sizeof(func_name), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }

    if (!enif_is_list(env, argv[2])) {
        return enif_make_badarg(env);
    }

    wasmtime_context_t *context = wasmtime_store_context(inst->store);

    /* Get the function */
    wasmtime_extern_t func_extern;
    if (!wasmtime_instance_export_get(context, &inst->instance, func_name, strlen(func_name), &func_extern)) {
        return make_error(env, "function_not_found");
    }

    if (func_extern.kind != WASMTIME_EXTERN_FUNC) {
        return make_error(env, "not_a_function");
    }

    wasmtime_func_t func = func_extern.of.func;

    /* Get wasm_alloc and wasm_free functions */
    wasmtime_extern_t alloc_extern, free_extern;
    wasmtime_func_t alloc_func, free_func;
    int has_alloc = 0, has_free = 0;

    if (wasmtime_instance_export_get(context, &inst->instance, "wasm_alloc", 10, &alloc_extern)) {
        if (alloc_extern.kind == WASMTIME_EXTERN_FUNC) {
            alloc_func = alloc_extern.of.func;
            has_alloc = 1;
        }
    }
    if (wasmtime_instance_export_get(context, &inst->instance, "wasm_free", 9, &free_extern)) {
        if (free_extern.kind == WASMTIME_EXTERN_FUNC) {
            free_func = free_extern.of.func;
            has_free = 1;
        }
    }

    if (!has_alloc || !inst->has_memory) {
        return make_error(env, "missing_alloc_or_memory");
    }

    /* Process arguments - each arg is an ETF-encoded binary */
    unsigned int arg_count;
    enif_get_list_length(env, argv[2], &arg_count);

    /* We need ptr and len for each argument */
    wasmtime_val_t *wasm_args = malloc(arg_count * 2 * sizeof(wasmtime_val_t));
    int32_t *ptrs = malloc(arg_count * sizeof(int32_t));
    int32_t *sizes = malloc(arg_count * sizeof(int32_t));

    ERL_NIF_TERM list = argv[2];
    ERL_NIF_TERM head;
    unsigned int i = 0;

    while (enif_get_list_cell(env, list, &head, &list)) {
        ErlNifBinary bin;
        if (!enif_inspect_binary(env, head, &bin)) {
            free(wasm_args);
            free(ptrs);
            free(sizes);
            return enif_make_badarg(env);
        }

        /* Allocate memory in WASM for this argument */
        wasmtime_val_t alloc_args[1] = {{ .kind = WASMTIME_I32, .of.i32 = bin.size }};
        wasmtime_val_t alloc_result[1];
        wasm_trap_t *trap = NULL;

        wasmtime_error_t *error = wasmtime_func_call(context, &alloc_func, alloc_args, 1, alloc_result, 1, &trap);
        if (error || trap) {
            if (trap) wasm_trap_delete(trap);
            if (error) wasmtime_error_delete(error);
            free(wasm_args);
            free(ptrs);
            free(sizes);
            return make_error(env, "alloc_failed");
        }

        int32_t ptr = alloc_result[0].of.i32;
        ptrs[i] = ptr;
        sizes[i] = bin.size;

        /* Copy data to WASM memory */
        uint8_t *mem_data = wasmtime_memory_data(context, &inst->memory);
        memcpy(mem_data + ptr, bin.data, bin.size);

        /* Set up args: ptr, len pairs */
        wasm_args[i * 2].kind = WASMTIME_I32;
        wasm_args[i * 2].of.i32 = ptr;
        wasm_args[i * 2 + 1].kind = WASMTIME_I32;
        wasm_args[i * 2 + 1].of.i32 = bin.size;
        i++;
    }

    /* Call the function */
    wasmtime_val_t results[1];
    wasm_trap_t *trap = NULL;
    wasmtime_error_t *error = wasmtime_func_call(context, &func, wasm_args, arg_count * 2, results, 1, &trap);

    /* Free input argument memory */
    if (has_free) {
        for (unsigned int j = 0; j < arg_count; j++) {
            wasmtime_val_t free_args[2] = {
                { .kind = WASMTIME_I32, .of.i32 = ptrs[j] },
                { .kind = WASMTIME_I32, .of.i32 = sizes[j] }
            };
            wasmtime_func_call(context, &free_func, free_args, 2, NULL, 0, NULL);
        }
    }

    free(wasm_args);
    free(ptrs);
    free(sizes);

    if (error) {
        return make_wasmtime_error(env, error);
    }
    if (trap) {
        wasm_trap_delete(trap);
        return make_error(env, "function_trapped");
    }

    /* Read result from memory */
    /* Result format: ptr to {len: u32 (4 bytes LE), data: [u8; len]} */
    if (results[0].kind == WASMTIME_I32) {
        int32_t result_ptr = results[0].of.i32;
        uint8_t *mem_data = wasmtime_memory_data(context, &inst->memory);

        /* Read length (first 4 bytes, little-endian) */
        uint32_t result_len = (uint32_t)mem_data[result_ptr] |
                              ((uint32_t)mem_data[result_ptr + 1] << 8) |
                              ((uint32_t)mem_data[result_ptr + 2] << 16) |
                              ((uint32_t)mem_data[result_ptr + 3] << 24);

        /* Create binary with result data */
        ERL_NIF_TERM result_binary;
        unsigned char *result_buf = enif_make_new_binary(env, result_len, &result_binary);
        memcpy(result_buf, mem_data + result_ptr + 4, result_len);

        /* Free result memory */
        if (has_free) {
            wasmtime_val_t free_args[2] = {
                { .kind = WASMTIME_I32, .of.i32 = result_ptr },
                { .kind = WASMTIME_I32, .of.i32 = result_len + 4 }
            };
            wasmtime_func_call(context, &free_func, free_args, 2, NULL, 0, NULL);
        }

        return enif_make_tuple2(env, ATOM_OK, result_binary);
    }

    return enif_make_tuple2(env, ATOM_OK, ATOM_UNDEFINED);
}

/* NIF: get_exports_nif(Ref) -> {ok, Exports} | {error, Reason} */
static ERL_NIF_TERM get_exports_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    erl_wasm_instance_t *inst;
    if (!enif_get_resource(env, argv[0], WASM_INSTANCE_RESOURCE, (void **)&inst)) {
        return enif_make_badarg(env);
    }

    wasm_exporttype_vec_t export_types;
    wasmtime_module_exports(inst->module, &export_types);

    ERL_NIF_TERM keys[64], values[64];
    int idx = 0;

    for (size_t i = 0; i < export_types.size && idx < 64; i++) {
        const wasm_name_t *name = wasm_exporttype_name(export_types.data[i]);
        const wasm_externtype_t *type = wasm_exporttype_type(export_types.data[i]);

        if (wasm_externtype_kind(type) == WASM_EXTERN_FUNC) {
            const wasm_functype_t *func_type = wasm_externtype_as_functype_const(type);
            const wasm_valtype_vec_t *params = wasm_functype_params(func_type);

            keys[idx] = enif_make_atom_len(env, name->data, name->size);
            values[idx] = enif_make_int(env, (int)params->size);
            idx++;
        }
    }
    wasm_exporttype_vec_delete(&export_types);

    ERL_NIF_TERM exports_map;
    enif_make_map_from_arrays(env, keys, values, idx, &exports_map);

    return enif_make_tuple2(env, ATOM_OK, exports_map);
}

/* NIF: get_memory_nif(Ref, {Offset, Length}) -> {ok, Binary} | {error, Reason} */
static ERL_NIF_TERM get_memory_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    erl_wasm_instance_t *inst;
    int offset, length;
    const ERL_NIF_TERM *tuple;
    int arity;

    if (!enif_get_resource(env, argv[0], WASM_INSTANCE_RESOURCE, (void **)&inst)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_tuple(env, argv[1], &arity, &tuple) || arity != 2) {
        return enif_make_badarg(env);
    }

    if (!enif_get_int(env, tuple[0], &offset) || !enif_get_int(env, tuple[1], &length)) {
        return enif_make_badarg(env);
    }

    if (!inst->has_memory) {
        return make_error(env, "no_memory");
    }

    wasmtime_context_t *context = wasmtime_store_context(inst->store);
    size_t mem_size = wasmtime_memory_data_size(context, &inst->memory);

    if (offset < 0 || length < 0 || (size_t)(offset + length) > mem_size) {
        return make_error(env, "out_of_bounds");
    }

    uint8_t *mem_data = wasmtime_memory_data(context, &inst->memory);

    ERL_NIF_TERM binary;
    unsigned char *buf = enif_make_new_binary(env, length, &binary);
    memcpy(buf, mem_data + offset, length);

    return enif_make_tuple2(env, ATOM_OK, binary);
}

/* NIF: set_memory_nif(Ref, Offset, Data) -> ok | {error, Reason} */
static ERL_NIF_TERM set_memory_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    erl_wasm_instance_t *inst;
    int offset;
    ErlNifBinary data;

    if (!enif_get_resource(env, argv[0], WASM_INSTANCE_RESOURCE, (void **)&inst)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_int(env, argv[1], &offset)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[2], &data)) {
        return enif_make_badarg(env);
    }

    if (!inst->has_memory) {
        return make_error(env, "no_memory");
    }

    wasmtime_context_t *context = wasmtime_store_context(inst->store);
    size_t mem_size = wasmtime_memory_data_size(context, &inst->memory);

    if (offset < 0 || (size_t)(offset + data.size) > mem_size) {
        return make_error(env, "out_of_bounds");
    }

    uint8_t *mem_data = wasmtime_memory_data(context, &inst->memory);
    memcpy(mem_data + offset, data.data, data.size);

    return ATOM_OK;
}

/* NIF: validate_module_nif(WasmBinary) -> ok | {error, Reason} */
static ERL_NIF_TERM validate_module_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary wasm_binary;

    if (!enif_inspect_binary(env, argv[0], &wasm_binary)) {
        return enif_make_badarg(env);
    }

    wasm_engine_t *engine = wasm_engine_new();
    if (!engine) {
        return make_error(env, "failed_to_create_engine");
    }

    wasmtime_error_t *error = wasmtime_module_validate(engine, wasm_binary.data, wasm_binary.size);
    wasm_engine_delete(engine);

    if (error) {
        return make_wasmtime_error(env, error);
    }

    return ATOM_OK;
}

/* NIF function table */
static ErlNifFunc nif_funcs[] = {
    {"load_module_nif", 2, load_module_nif, 0},
    {"unload_module_nif", 1, unload_module_nif, 0},
    {"call_function_nif", 4, call_function_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"get_exports_nif", 1, get_exports_nif, 0},
    {"get_memory_nif", 2, get_memory_nif, 0},
    {"set_memory_nif", 3, set_memory_nif, 0},
    {"validate_module_nif", 1, validate_module_nif, 0}
};

/* NIF load callback */
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;

    WASM_INSTANCE_RESOURCE = enif_open_resource_type(
        env, NULL, "wasm_instance",
        wasm_instance_dtor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL
    );

    if (!WASM_INSTANCE_RESOURCE) {
        return -1;
    }

    ATOM_OK = make_atom(env, "ok");
    ATOM_ERROR = make_atom(env, "error");
    ATOM_UNDEFINED = make_atom(env, "undefined");
    ATOM_REPLY = make_atom(env, "reply");
    ATOM_NOREPLY = make_atom(env, "noreply");

    return 0;
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info) {
    (void)old_priv_data;
    return load(env, priv_data, load_info);
}

ERL_NIF_INIT(wasm_runtime_nif, nif_funcs, load, NULL, upgrade, NULL)
