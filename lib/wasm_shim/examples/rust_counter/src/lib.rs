//! Rust Counter Server Example for gen_wasmserver
//!
//! This is an example implementation of a gen_wasmserver in Rust using
//! the `eetf` crate for Erlang External Term Format encoding/decoding.
//!
//! # Usage from Erlang
//!
//! ```erlang
//! {ok, Wasm} = file:read_file("rust_counter.wasm"),
//! {ok, Pid} = gen_wasmserver:start_link(Wasm, 0, []),
//! gen_wasmserver:call(Pid, get),           %% -> 0
//! gen_wasmserver:cast(Pid, increment),
//! gen_wasmserver:call(Pid, get),           %% -> 1
//! gen_wasmserver:call(Pid, {set, 100}),    %% -> 1 (old value)
//! gen_wasmserver:call(Pid, get).           %% -> 100
//! ```
//!
//! # Building
//!
//! ```bash
//! cargo build --release --target wasm32-wasip1
//! ```

use eetf::{Atom, Term};
use num_traits::ToPrimitive;
use std::io::Cursor;
use std::sync::Mutex;

// ============================================================================
// Global State
// ============================================================================

/// Initial counter value (for reset) - thread-safe
static INITIAL_VALUE: Mutex<i64> = Mutex::new(0);

// ============================================================================
// Helper Functions
// ============================================================================

/// Decode ETF bytes into a Term
fn decode_term(data: &[u8]) -> Option<Term> {
    Term::decode(Cursor::new(data)).ok()
}

/// Encode a Term to ETF bytes
fn encode_term(term: &Term) -> Vec<u8> {
    let mut buf = Vec::new();
    term.encode(&mut buf).expect("encoding should not fail");
    buf
}

/// Extract integer value from a Term
fn term_to_i64(term: &Term) -> Option<i64> {
    match term {
        Term::FixInteger(fix) => Some(fix.value as i64),
        Term::BigInteger(big) => big.to_i64(),
        _ => None,
    }
}

/// Check if term is an atom with the given name
fn is_atom(term: &Term, name: &str) -> bool {
    match term {
        Term::Atom(atom) => atom.name == name,
        _ => false,
    }
}

/// Get tuple elements if term is a tuple
fn as_tuple(term: &Term) -> Option<&[Term]> {
    match term {
        Term::Tuple(tuple) => Some(&tuple.elements),
        _ => None,
    }
}

/// Create an atom term
fn atom(name: &str) -> Term {
    Term::Atom(Atom::from(name))
}

/// Create an integer term
fn integer(value: i64) -> Term {
    Term::FixInteger(eetf::FixInteger { value: value as i32 })
}

/// Create a 2-tuple
fn tuple2(a: Term, b: Term) -> Term {
    Term::Tuple(eetf::Tuple {
        elements: vec![a, b],
    })
}

/// Create a 3-tuple
fn tuple3(a: Term, b: Term, c: Term) -> Term {
    Term::Tuple(eetf::Tuple {
        elements: vec![a, b, c],
    })
}

/// Create a 4-tuple
fn tuple4(a: Term, b: Term, c: Term, d: Term) -> Term {
    Term::Tuple(eetf::Tuple {
        elements: vec![a, b, c, d],
    })
}

// ============================================================================
// gen_wasmserver Response Builders
// ============================================================================

/// Build {ok, State} init result
fn init_ok(state: Term) -> Term {
    tuple2(atom("ok"), state)
}

/// Build {reply, Reply, NewState} call result
fn call_reply(reply: Term, new_state: Term) -> Term {
    tuple3(atom("reply"), reply, new_state)
}

/// Build {noreply, NewState} result
fn noreply(new_state: Term) -> Term {
    tuple2(atom("noreply"), new_state)
}

/// Write result to output pointers
fn write_result(term: &Term, out_data: *mut *mut u8, out_len: *mut u32) -> i32 {
    let encoded = encode_term(term);
    let len = encoded.len();
    let ptr = wasm_alloc(len as u32);
    if ptr.is_null() {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(encoded.as_ptr(), ptr, len);
        *out_data = ptr;
        *out_len = len as u32;
    }
    0
}

// ============================================================================
// WASM Memory Exports
// ============================================================================

/// Allocate memory in WASM linear memory
#[no_mangle]
pub extern "C" fn wasm_alloc(size: u32) -> *mut u8 {
    let layout = std::alloc::Layout::from_size_align(size as usize, 8).unwrap();
    unsafe { std::alloc::alloc(layout) }
}

/// Free memory in WASM linear memory
#[no_mangle]
pub extern "C" fn wasm_free(ptr: *mut u8, size: u32) {
    if !ptr.is_null() && size > 0 {
        let layout = std::alloc::Layout::from_size_align(size as usize, 8).unwrap();
        unsafe { std::alloc::dealloc(ptr, layout) };
    }
}

// ============================================================================
// gen_wasmserver Callback Implementations
// ============================================================================

/// Initialize the counter server
///
/// Args: integer (initial value) or ignored for default 0
/// Returns: {ok, State}
#[no_mangle]
pub extern "C" fn wasm_init(
    args_data: *const u8,
    args_len: u32,
    result_data: *mut *mut u8,
    result_len: *mut u32,
) -> i32 {
    let args = unsafe { std::slice::from_raw_parts(args_data, args_len as usize) };

    // Decode initial value from args
    let initial = decode_term(args)
        .and_then(|t| term_to_i64(&t))
        .unwrap_or(0);

    // Store initial value for reset
    if let Ok(mut guard) = INITIAL_VALUE.lock() {
        *guard = initial;
    }

    // Create initial state and return {ok, State}
    let state = integer(initial);
    let result = init_ok(state);

    write_result(&result, result_data, result_len)
}

/// Handle synchronous calls
///
/// Supported requests:
/// - `get` -> returns current value
/// - `{set, N}` -> sets to N, returns old value
/// - `{add, N}` -> adds N, returns new value
#[no_mangle]
pub extern "C" fn wasm_handle_call(
    request_data: *const u8,
    request_len: u32,
    _from_data: *const u8,
    _from_len: u32,
    state_data: *const u8,
    state_len: u32,
    result_data: *mut *mut u8,
    result_len: *mut u32,
) -> i32 {
    let request_bytes = unsafe { std::slice::from_raw_parts(request_data, request_len as usize) };
    let state_bytes = unsafe { std::slice::from_raw_parts(state_data, state_len as usize) };

    // Decode current state
    let current = decode_term(state_bytes)
        .and_then(|t| term_to_i64(&t))
        .unwrap_or(0);

    // Decode request
    let request = match decode_term(request_bytes) {
        Some(term) => term,
        None => {
            let result = call_reply(
                tuple2(atom("error"), atom("decode_failed")),
                integer(current),
            );
            return write_result(&result, result_data, result_len);
        }
    };

    // Handle different requests
    let (reply, new_counter) = if is_atom(&request, "get") {
        // get -> return current value
        (integer(current), current)
    } else if let Some(elements) = as_tuple(&request) {
        if elements.len() == 2 {
            let tag = &elements[0];
            let value = &elements[1];

            if is_atom(tag, "set") {
                // {set, N} -> set to N, return old value
                if let Some(n) = term_to_i64(value) {
                    (integer(current), n)
                } else {
                    (tuple2(atom("error"), atom("bad_value")), current)
                }
            } else if is_atom(tag, "add") {
                // {add, N} -> add N, return new value
                if let Some(n) = term_to_i64(value) {
                    let new_value = current + n;
                    (integer(new_value), new_value)
                } else {
                    (tuple2(atom("error"), atom("bad_value")), current)
                }
            } else {
                (tuple2(atom("error"), atom("unknown_request")), current)
            }
        } else {
            (tuple2(atom("error"), atom("unknown_request")), current)
        }
    } else {
        (tuple2(atom("error"), atom("unknown_request")), current)
    };

    let new_state = integer(new_counter);
    let result = call_reply(reply, new_state);

    write_result(&result, result_data, result_len)
}

/// Handle asynchronous casts
///
/// Supported requests:
/// - `increment` -> adds 1
/// - `{increment, N}` -> adds N
/// - `decrement` -> subtracts 1
/// - `{decrement, N}` -> subtracts N
/// - `reset` -> resets to initial value
/// - `{multiply, N}` -> multiplies by N
#[no_mangle]
pub extern "C" fn wasm_handle_cast(
    request_data: *const u8,
    request_len: u32,
    state_data: *const u8,
    state_len: u32,
    result_data: *mut *mut u8,
    result_len: *mut u32,
) -> i32 {
    let request_bytes = unsafe { std::slice::from_raw_parts(request_data, request_len as usize) };
    let state_bytes = unsafe { std::slice::from_raw_parts(state_data, state_len as usize) };

    // Decode current state
    let current = decode_term(state_bytes)
        .and_then(|t| term_to_i64(&t))
        .unwrap_or(0);

    // Decode request
    let request = match decode_term(request_bytes) {
        Some(term) => term,
        None => {
            let result = noreply(integer(current));
            return write_result(&result, result_data, result_len);
        }
    };

    // Handle different requests
    let new_counter = if is_atom(&request, "increment") {
        current + 1
    } else if is_atom(&request, "decrement") {
        current - 1
    } else if is_atom(&request, "reset") {
        INITIAL_VALUE.lock().map(|g| *g).unwrap_or(0)
    } else if let Some(elements) = as_tuple(&request) {
        if elements.len() == 2 {
            let tag = &elements[0];
            let value = &elements[1];

            if is_atom(tag, "increment") {
                term_to_i64(value).map(|n| current + n).unwrap_or(current)
            } else if is_atom(tag, "decrement") {
                term_to_i64(value).map(|n| current - n).unwrap_or(current)
            } else if is_atom(tag, "multiply") {
                term_to_i64(value).map(|n| current * n).unwrap_or(current)
            } else if is_atom(tag, "set") {
                term_to_i64(value).unwrap_or(current)
            } else {
                current
            }
        } else {
            current
        }
    } else {
        current
    };

    let new_state = integer(new_counter);
    let result = noreply(new_state);

    write_result(&result, result_data, result_len)
}

/// Handle info messages - just pass through state unchanged
#[no_mangle]
pub extern "C" fn wasm_handle_info(
    _info_data: *const u8,
    _info_len: u32,
    state_data: *const u8,
    state_len: u32,
    result_data: *mut *mut u8,
    result_len: *mut u32,
) -> i32 {
    let state_bytes = unsafe { std::slice::from_raw_parts(state_data, state_len as usize) };

    let current = decode_term(state_bytes)
        .and_then(|t| term_to_i64(&t))
        .unwrap_or(0);

    let new_state = integer(current);
    let result = noreply(new_state);

    write_result(&result, result_data, result_len)
}

/// Handle termination - nothing to clean up
#[no_mangle]
pub extern "C" fn wasm_terminate(
    _reason_data: *const u8,
    _reason_len: u32,
    _state_data: *const u8,
    _state_len: u32,
) -> i32 {
    0 // Success
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_decode_integer() {
        let term = integer(42);
        let encoded = encode_term(&term);
        let decoded = decode_term(&encoded).unwrap();
        assert_eq!(term_to_i64(&decoded), Some(42));
    }

    #[test]
    fn test_encode_decode_atom() {
        let term = atom("hello");
        let encoded = encode_term(&term);
        let decoded = decode_term(&encoded).unwrap();
        assert!(is_atom(&decoded, "hello"));
    }

    #[test]
    fn test_encode_decode_tuple() {
        let term = tuple2(atom("ok"), integer(123));
        let encoded = encode_term(&term);
        let decoded = decode_term(&encoded).unwrap();

        let elements = as_tuple(&decoded).unwrap();
        assert_eq!(elements.len(), 2);
        assert!(is_atom(&elements[0], "ok"));
        assert_eq!(term_to_i64(&elements[1]), Some(123));
    }

    #[test]
    fn test_init_ok() {
        let state = integer(0);
        let result = init_ok(state);

        let elements = as_tuple(&result).unwrap();
        assert_eq!(elements.len(), 2);
        assert!(is_atom(&elements[0], "ok"));
    }

    #[test]
    fn test_call_reply() {
        let reply = integer(42);
        let state = integer(100);
        let result = call_reply(reply, state);

        let elements = as_tuple(&result).unwrap();
        assert_eq!(elements.len(), 3);
        assert!(is_atom(&elements[0], "reply"));
    }
}
