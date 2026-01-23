//! Rust Counter Server Example for gen_wasmserver
//!
//! # Building
//! ```bash
//! cargo build --release --target wasm32-wasip1
//! ```

use eetf::{Atom, Term};
use num_traits::ToPrimitive;
use std::io::Cursor;
use std::sync::Mutex;

// Global state for initial value
static INITIAL_VALUE: Mutex<i64> = Mutex::new(0);

// ============================================================================
// Helper Functions
// ============================================================================

fn decode_term(data: &[u8]) -> Option<Term> {
    Term::decode(Cursor::new(data)).ok()
}

fn encode_term(term: &Term) -> Vec<u8> {
    let mut buf = Vec::new();
    term.encode(&mut buf).expect("encoding should not fail");
    buf
}

fn term_to_i64(term: &Term) -> Option<i64> {
    match term {
        Term::FixInteger(fix) => Some(fix.value as i64),
        Term::BigInteger(big) => big.to_i64(),
        _ => None,
    }
}

fn is_atom(term: &Term, name: &str) -> bool {
    match term {
        Term::Atom(atom) => atom.name == name,
        _ => false,
    }
}

fn as_tuple(term: &Term) -> Option<&[Term]> {
    match term {
        Term::Tuple(tuple) => Some(&tuple.elements),
        _ => None,
    }
}

fn atom(name: &str) -> Term {
    Term::Atom(Atom::from(name))
}

fn integer(value: i64) -> Term {
    Term::FixInteger(eetf::FixInteger { value: value as i32 })
}

fn tuple2(a: Term, b: Term) -> Term {
    Term::Tuple(eetf::Tuple { elements: vec![a, b] })
}

fn tuple3(a: Term, b: Term, c: Term) -> Term {
    Term::Tuple(eetf::Tuple { elements: vec![a, b, c] })
}

// ============================================================================
// Result builders
// ============================================================================

fn init_ok(state: Term) -> Term {
    tuple2(atom("ok"), state)
}

fn call_reply(reply: Term, new_state: Term) -> Term {
    tuple3(atom("reply"), reply, new_state)
}

fn noreply(new_state: Term) -> Term {
    tuple2(atom("noreply"), new_state)
}

/// Allocate and write a length-prefixed result buffer
/// Format: [len: u32 LE][data: u8[len]]
fn alloc_result(term: &Term) -> *mut u8 {
    let encoded = encode_term(term);
    let total_size = 4 + encoded.len();
    let ptr = wasm_alloc(total_size as u32);
    if ptr.is_null() {
        return ptr;
    }
    unsafe {
        // Write length as little-endian u32
        let len_bytes = (encoded.len() as u32).to_le_bytes();
        std::ptr::copy_nonoverlapping(len_bytes.as_ptr(), ptr, 4);
        // Write data
        std::ptr::copy_nonoverlapping(encoded.as_ptr(), ptr.add(4), encoded.len());
    }
    ptr
}

// ============================================================================
// Memory exports
// ============================================================================

#[no_mangle]
pub extern "C" fn wasm_alloc(size: u32) -> *mut u8 {
    if size == 0 {
        return std::ptr::null_mut();
    }
    let layout = std::alloc::Layout::from_size_align(size as usize, 8).unwrap();
    unsafe { std::alloc::alloc(layout) }
}

#[no_mangle]
pub extern "C" fn wasm_free(ptr: *mut u8, size: u32) {
    if !ptr.is_null() && size > 0 {
        let layout = std::alloc::Layout::from_size_align(size as usize, 8).unwrap();
        unsafe { std::alloc::dealloc(ptr, layout) };
    }
}

// ============================================================================
// gen_wasmserver callbacks - Simple ABI: (ptr, len, ...) -> ptr to len-prefixed result
// ============================================================================

/// wasm_init(args_ptr, args_len) -> ptr to result
#[no_mangle]
pub extern "C" fn wasm_init(args_ptr: *const u8, args_len: u32) -> *mut u8 {
    let args = unsafe { std::slice::from_raw_parts(args_ptr, args_len as usize) };

    let initial = decode_term(args)
        .and_then(|t| term_to_i64(&t))
        .unwrap_or(0);

    if let Ok(mut guard) = INITIAL_VALUE.lock() {
        *guard = initial;
    }

    let state = integer(initial);
    let result = init_ok(state);
    alloc_result(&result)
}

/// wasm_handle_call(req_ptr, req_len, from_ptr, from_len, state_ptr, state_len) -> ptr
#[no_mangle]
pub extern "C" fn wasm_handle_call(
    req_ptr: *const u8, req_len: u32,
    _from_ptr: *const u8, _from_len: u32,
    state_ptr: *const u8, state_len: u32,
) -> *mut u8 {
    let req_bytes = unsafe { std::slice::from_raw_parts(req_ptr, req_len as usize) };
    let state_bytes = unsafe { std::slice::from_raw_parts(state_ptr, state_len as usize) };

    let current = decode_term(state_bytes)
        .and_then(|t| term_to_i64(&t))
        .unwrap_or(0);

    let request = match decode_term(req_bytes) {
        Some(term) => term,
        None => {
            let result = call_reply(tuple2(atom("error"), atom("decode_failed")), integer(current));
            return alloc_result(&result);
        }
    };

    let (reply, new_counter) = if is_atom(&request, "get") {
        (integer(current), current)
    } else if let Some(elements) = as_tuple(&request) {
        if elements.len() == 2 {
            let tag = &elements[0];
            let value = &elements[1];

            if is_atom(tag, "set") {
                if let Some(n) = term_to_i64(value) {
                    (integer(current), n)  // Return old value, set new
                } else {
                    (tuple2(atom("error"), atom("bad_value")), current)
                }
            } else if is_atom(tag, "add") {
                if let Some(n) = term_to_i64(value) {
                    let new_val = current + n;
                    (integer(new_val), new_val)
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

    let result = call_reply(reply, integer(new_counter));
    alloc_result(&result)
}

/// wasm_handle_cast(req_ptr, req_len, state_ptr, state_len) -> ptr
#[no_mangle]
pub extern "C" fn wasm_handle_cast(
    req_ptr: *const u8, req_len: u32,
    state_ptr: *const u8, state_len: u32,
) -> *mut u8 {
    let req_bytes = unsafe { std::slice::from_raw_parts(req_ptr, req_len as usize) };
    let state_bytes = unsafe { std::slice::from_raw_parts(state_ptr, state_len as usize) };

    let current = decode_term(state_bytes)
        .and_then(|t| term_to_i64(&t))
        .unwrap_or(0);

    let request = match decode_term(req_bytes) {
        Some(term) => term,
        None => {
            let result = noreply(integer(current));
            return alloc_result(&result);
        }
    };

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

    let result = noreply(integer(new_counter));
    alloc_result(&result)
}

/// wasm_handle_info(info_ptr, info_len, state_ptr, state_len) -> ptr
#[no_mangle]
pub extern "C" fn wasm_handle_info(
    _info_ptr: *const u8, _info_len: u32,
    state_ptr: *const u8, state_len: u32,
) -> *mut u8 {
    let state_bytes = unsafe { std::slice::from_raw_parts(state_ptr, state_len as usize) };

    let current = decode_term(state_bytes)
        .and_then(|t| term_to_i64(&t))
        .unwrap_or(0);

    let result = noreply(integer(current));
    alloc_result(&result)
}

/// wasm_terminate(reason_ptr, reason_len, state_ptr, state_len) -> ptr
#[no_mangle]
pub extern "C" fn wasm_terminate(
    _reason_ptr: *const u8, _reason_len: u32,
    _state_ptr: *const u8, _state_len: u32,
) -> *mut u8 {
    // Return {ok} or just ok encoded
    let result = atom("ok");
    alloc_result(&result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_decode() {
        let term = integer(42);
        let enc = encode_term(&term);
        let dec = decode_term(&enc).unwrap();
        assert_eq!(term_to_i64(&dec), Some(42));
    }
}
