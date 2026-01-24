//! Rust NIF for WebAssembly runtime integration using wasmtime.
//!
//! This NIF provides functions for loading, executing, and managing WASM modules
//! from Erlang code.

use rustler::{Atom, Binary, Encoder, Env, Error, NifResult, OwnedBinary, ResourceArc, Term};
use std::collections::HashMap;
use std::sync::Mutex;
use wasmtime::*;
use wasmtime_wasi::preview1::WasiP1Ctx;
use wasmtime_wasi::WasiCtxBuilder;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        badarg,
        not_found,
        wasm_error,
        trap,
        memory_access,
        decode_failed,
        function_not_found,
        invalid_arity,
    }
}

/// WASM instance resource that holds the engine, store, and instance.
struct WasmInstance {
    engine: Engine,
    store: Mutex<Store<WasiP1Ctx>>,
    instance: Instance,
    memory: Option<Memory>,
    exports: HashMap<String, usize>,
}

/// Resource wrapper for thread-safe access
struct WasmResource(Mutex<WasmInstance>);

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(WasmResource, env);
    true
}

/// Load a WASM module from binary data.
/// Returns {ok, Ref, ExportsMap} | {error, Reason}
#[rustler::nif]
fn load_module_nif<'a>(
    env: Env<'a>,
    wasm_binary: Binary<'a>,
    _options: Term<'a>,
) -> NifResult<Term<'a>> {
    let wasm_bytes = wasm_binary.as_slice();

    // Create engine with default config
    let engine = Engine::default();

    // Compile the module
    let module = match Module::new(&engine, wasm_bytes) {
        Ok(m) => m,
        Err(e) => {
            return Ok((atoms::error(), format!("compile_failed: {}", e)).encode(env));
        }
    };

    // Create WASI context
    let wasi_ctx = WasiCtxBuilder::new()
        .inherit_stdout()
        .inherit_stderr()
        .build_p1();

    // Create store with WASI context
    let mut store = Store::new(&engine, wasi_ctx);

    // Create linker and add WASI
    let mut linker = Linker::new(&engine);
    if let Err(e) = wasmtime_wasi::preview1::add_to_linker_sync(&mut linker, |ctx| ctx) {
        return Ok((atoms::error(), format!("wasi_init_failed: {}", e)).encode(env));
    }

    // Instantiate the module
    let instance = match linker.instantiate(&mut store, &module) {
        Ok(i) => i,
        Err(e) => {
            return Ok((atoms::error(), format!("instantiate_failed: {}", e)).encode(env));
        }
    };

    // Get memory if exported
    let memory = instance.get_memory(&mut store, "memory");

    // Build exports map
    let mut exports = HashMap::new();
    for export in module.exports() {
        if let ExternType::Func(func_type) = export.ty() {
            exports.insert(export.name().to_string(), func_type.params().len());
        }
    }

    // Create exports term
    let exports_term: Vec<(Term, Term)> = exports
        .iter()
        .map(|(name, arity)| {
            (
                Atom::from_str(env, name)
                    .unwrap_or_else(|_| atoms::error())
                    .encode(env),
                (*arity).encode(env),
            )
        })
        .collect();
    let exports_map = Term::map_from_pairs(env, &exports_term).unwrap();

    let wasm_instance = WasmInstance {
        engine,
        store: Mutex::new(store),
        instance,
        memory,
        exports,
    };

    let resource = ResourceArc::new(WasmResource(Mutex::new(wasm_instance)));

    Ok((atoms::ok(), resource, exports_map).encode(env))
}

/// Unload a WASM module.
#[rustler::nif]
fn unload_module_nif(_resource: ResourceArc<WasmResource>) -> Atom {
    // Resource is automatically dropped when there are no more references
    atoms::ok()
}

/// Call a WASM function.
/// Args are passed as a list of binaries (ETF-encoded terms).
/// Returns {ok, Binary} | {error, Reason}
#[rustler::nif]
fn call_function_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<WasmResource>,
    function: Binary<'a>,
    args: Vec<Binary<'a>>,
) -> NifResult<Term<'a>> {
    // Convert function binary to string
    let func_name = std::str::from_utf8(function.as_slice())
        .map_err(|_| Error::BadArg)?
        .to_string();

    let wasm_resource = match resource.0.lock() {
        Ok(guard) => guard,
        Err(_) => return Ok((atoms::error(), "lock_failed").encode(env)),
    };

    let mut store = match wasm_resource.store.lock() {
        Ok(guard) => guard,
        Err(_) => return Ok((atoms::error(), "store_lock_failed").encode(env)),
    };

    // Look up the function
    let func = match wasm_resource.instance.get_func(&mut *store, &func_name) {
        Some(f) => f,
        None => return Ok((atoms::error(), atoms::function_not_found()).encode(env)),
    };

    // Get memory for passing data
    let memory = match wasm_resource.memory.as_ref() {
        Some(m) => m,
        None => return Ok((atoms::error(), "no_memory").encode(env)),
    };

    // Get the alloc function
    let alloc_func = match wasm_resource.instance.get_func(&mut *store, "wasm_alloc") {
        Some(f) => f,
        None => return Ok((atoms::error(), "no_alloc_function").encode(env)),
    };

    // Write each arg to WASM memory and build ptr/len pairs
    let mut wasm_args: Vec<Val> = Vec::new();

    for arg in &args {
        let arg_bytes = arg.as_slice();
        let len = arg_bytes.len() as u32;

        // Allocate memory in WASM
        let mut results = [Val::I32(0)];
        if let Err(e) = alloc_func.call(&mut *store, &[Val::I32(len as i32)], &mut results) {
            return Ok((atoms::error(), format!("alloc_failed: {}", e)).encode(env));
        }

        let ptr = match results[0] {
            Val::I32(p) => p as u32,
            _ => return Ok((atoms::error(), "alloc_bad_return").encode(env)),
        };

        // Write data to WASM memory
        let mem_data = memory.data_mut(&mut *store);
        if (ptr as usize) + (len as usize) > mem_data.len() {
            return Ok((atoms::error(), atoms::memory_access()).encode(env));
        }
        mem_data[ptr as usize..(ptr as usize + len as usize)].copy_from_slice(arg_bytes);

        wasm_args.push(Val::I32(ptr as i32));
        wasm_args.push(Val::I32(len as i32));
    }

    // Call the function
    let mut results = [Val::I32(0)];
    if let Err(e) = func.call(&mut *store, &wasm_args, &mut results) {
        return Ok((atoms::error(), format!("call_failed: {}", e)).encode(env));
    }

    // Get the result pointer
    let result_ptr = match results[0] {
        Val::I32(p) => p as u32,
        _ => return Ok((atoms::error(), "bad_return_type").encode(env)),
    };

    if result_ptr == 0 {
        return Ok((atoms::error(), "null_result").encode(env));
    }

    // Read the length-prefixed result
    let mem_data = memory.data(&*store);
    if (result_ptr as usize) + 4 > mem_data.len() {
        return Ok((atoms::error(), atoms::memory_access()).encode(env));
    }

    let len_bytes: [u8; 4] = mem_data[result_ptr as usize..(result_ptr as usize + 4)]
        .try_into()
        .unwrap();
    let result_len = u32::from_le_bytes(len_bytes) as usize;

    let data_start = result_ptr as usize + 4;
    if data_start + result_len > mem_data.len() {
        return Ok((atoms::error(), atoms::memory_access()).encode(env));
    }

    // Copy result data
    let result_data = &mem_data[data_start..data_start + result_len];
    let mut owned = OwnedBinary::new(result_len).ok_or(Error::Atom("alloc_failed"))?;
    owned.as_mut_slice().copy_from_slice(result_data);

    Ok((atoms::ok(), owned.release(env)).encode(env))
}

/// Get exports from a WASM module.
#[rustler::nif]
fn get_exports_nif<'a>(env: Env<'a>, resource: ResourceArc<WasmResource>) -> NifResult<Term<'a>> {
    let wasm_resource = match resource.0.lock() {
        Ok(guard) => guard,
        Err(_) => return Ok((atoms::error(), "lock_failed").encode(env)),
    };

    let exports_term: Vec<(Term, Term)> = wasm_resource
        .exports
        .iter()
        .map(|(name, arity)| {
            (
                Atom::from_str(env, name)
                    .unwrap_or_else(|_| atoms::error())
                    .encode(env),
                (*arity).encode(env),
            )
        })
        .collect();

    let exports_map = Term::map_from_pairs(env, &exports_term)
        .map_err(|_| Error::Atom("map_build_failed"))?;

    Ok((atoms::ok(), exports_map).encode(env))
}

/// Get memory from a WASM module.
#[rustler::nif]
fn get_memory_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<WasmResource>,
    offset_length: (u32, u32),
) -> NifResult<Term<'a>> {
    let (offset, length) = offset_length;

    let wasm_resource = match resource.0.lock() {
        Ok(guard) => guard,
        Err(_) => return Ok((atoms::error(), "lock_failed").encode(env)),
    };

    let store = match wasm_resource.store.lock() {
        Ok(guard) => guard,
        Err(_) => return Ok((atoms::error(), "store_lock_failed").encode(env)),
    };

    let memory = match wasm_resource.memory.as_ref() {
        Some(m) => m,
        None => return Ok((atoms::error(), "no_memory").encode(env)),
    };

    let mem_data = memory.data(&*store);
    let start = offset as usize;
    let end = start + length as usize;

    if end > mem_data.len() {
        return Ok((atoms::error(), atoms::memory_access()).encode(env));
    }

    let mut owned = OwnedBinary::new(length as usize).ok_or(Error::Atom("alloc_failed"))?;
    owned.as_mut_slice().copy_from_slice(&mem_data[start..end]);

    Ok((atoms::ok(), owned.release(env)).encode(env))
}

/// Set memory in a WASM module.
#[rustler::nif]
fn set_memory_nif<'a>(
    env: Env<'a>,
    resource: ResourceArc<WasmResource>,
    offset: u32,
    data: Binary<'a>,
) -> NifResult<Term<'a>> {
    let wasm_resource = match resource.0.lock() {
        Ok(guard) => guard,
        Err(_) => return Ok((atoms::error(), "lock_failed").encode(env)),
    };

    let mut store = match wasm_resource.store.lock() {
        Ok(guard) => guard,
        Err(_) => return Ok((atoms::error(), "store_lock_failed").encode(env)),
    };

    let memory = match wasm_resource.memory.as_ref() {
        Some(m) => m,
        None => return Ok((atoms::error(), "no_memory").encode(env)),
    };

    let mem_data = memory.data_mut(&mut *store);
    let start = offset as usize;
    let data_slice = data.as_slice();
    let end = start + data_slice.len();

    if end > mem_data.len() {
        return Ok((atoms::error(), atoms::memory_access()).encode(env));
    }

    mem_data[start..end].copy_from_slice(data_slice);

    Ok(atoms::ok().encode(env))
}

/// Validate a WASM module.
#[rustler::nif]
fn validate_module_nif<'a>(env: Env<'a>, wasm_binary: Binary<'a>) -> NifResult<Term<'a>> {
    let wasm_bytes = wasm_binary.as_slice();

    let engine = Engine::default();

    match Module::validate(&engine, wasm_bytes) {
        Ok(()) => Ok(atoms::ok().encode(env)),
        Err(e) => Ok((atoms::error(), format!("invalid: {}", e)).encode(env)),
    }
}

rustler::init!("wasm_runtime_nif", load = load);
