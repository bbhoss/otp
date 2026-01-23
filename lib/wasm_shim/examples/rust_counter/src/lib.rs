//! Rust Counter Server Example for gen_wasmserver
//!
//! This is an example implementation of a gen_wasmserver in Rust.
//! It implements a simple counter that can be incremented, decremented,
//! and queried.
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
//! cargo build --release --target wasm32-unknown-unknown
//! # or with WASI support:
//! cargo build --release --target wasm32-wasi
//! ```

#![no_std]

extern crate alloc;

mod etf;
mod gen_wasmserver;

use alloc::vec::Vec;
use core::cell::RefCell;
use etf::Term;

// ============================================================================
// Global State
// ============================================================================

/// Initial counter value (for reset)
static INITIAL_VALUE: RefCell<i64> = RefCell::new(0);

// ============================================================================
// Memory Allocator for WASM
// ============================================================================

/// Simple bump allocator for WASM
mod allocator {
    use core::alloc::{GlobalAlloc, Layout};
    use core::cell::UnsafeCell;

    const HEAP_SIZE: usize = 65536; // 64KB

    struct BumpAllocator {
        heap: UnsafeCell<[u8; HEAP_SIZE]>,
        next: UnsafeCell<usize>,
    }

    unsafe impl Sync for BumpAllocator {}

    unsafe impl GlobalAlloc for BumpAllocator {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let next = &mut *self.next.get();
            let align = layout.align();
            let size = layout.size();

            // Align up
            let aligned = (*next + align - 1) & !(align - 1);

            if aligned + size > HEAP_SIZE {
                return core::ptr::null_mut();
            }

            *next = aligned + size;
            (self.heap.get() as *mut u8).add(aligned)
        }

        unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
            // Bump allocator doesn't support deallocation
        }
    }

    #[global_allocator]
    static ALLOCATOR: BumpAllocator = BumpAllocator {
        heap: UnsafeCell::new([0; HEAP_SIZE]),
        next: UnsafeCell::new(0),
    };
}

// ============================================================================
// Panic Handler
// ============================================================================

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

// ============================================================================
// WASM Memory Exports
// ============================================================================

/// Allocate memory in WASM linear memory
#[no_mangle]
pub extern "C" fn wasm_alloc(size: u32) -> *mut u8 {
    let layout = core::alloc::Layout::from_size_align(size as usize, 8).unwrap();
    unsafe { alloc::alloc::alloc(layout) }
}

/// Free memory in WASM linear memory
#[no_mangle]
pub extern "C" fn wasm_free(ptr: *mut u8, size: u32) {
    if !ptr.is_null() && size > 0 {
        let layout = core::alloc::Layout::from_size_align(size as usize, 8).unwrap();
        unsafe { alloc::alloc::dealloc(ptr, layout) };
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Read ETF data from WASM memory
unsafe fn read_etf_data(ptr: *const u8, len: u32) -> &'static [u8] {
    core::slice::from_raw_parts(ptr, len as usize)
}

/// Write result to WASM memory and return pointer
fn write_result(result: &Term, out_data: *mut *mut u8, out_len: *mut u32) -> i32 {
    match gen_wasmserver::encode_result(result) {
        Ok(encoded) => {
            let len = encoded.len();
            let ptr = wasm_alloc(len as u32);
            if ptr.is_null() {
                return -1;
            }
            unsafe {
                core::ptr::copy_nonoverlapping(encoded.as_ptr(), ptr, len);
                *out_data = ptr;
                *out_len = len as u32;
            }
            0
        }
        Err(_) => -1,
    }
}

/// Decode counter state from a Term
fn decode_state(term: &Term) -> i64 {
    term.as_integer().unwrap_or(0)
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
    let args = unsafe { read_etf_data(args_data, args_len) };

    // Decode initial value from args
    let initial = match etf::decode(args) {
        Ok(term) => term.as_integer().unwrap_or(0),
        Err(_) => 0,
    };

    // Store initial value for reset
    *INITIAL_VALUE.borrow_mut() = initial;

    // Create initial state
    let state = Term::integer(initial);
    let result = gen_wasmserver::init_ok(state);

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
    let request_bytes = unsafe { read_etf_data(request_data, request_len) };
    let state_bytes = unsafe { read_etf_data(state_data, state_len) };

    // Decode current state
    let current = match etf::decode(state_bytes) {
        Ok(term) => decode_state(&term),
        Err(_) => 0,
    };

    // Decode request
    let request = match etf::decode(request_bytes) {
        Ok(term) => term,
        Err(_) => {
            let result = gen_wasmserver::call_reply(
                Term::tuple2(Term::atom("error"), Term::atom("decode_failed")),
                Term::integer(current),
            );
            return write_result(&result, result_data, result_len);
        }
    };

    // Handle different requests
    let (reply, new_counter) = if request.is_atom_eq("get") {
        // get -> return current value
        (Term::integer(current), current)
    } else if let Some(tuple) = request.as_tuple() {
        if tuple.len() == 2 {
            let tag = &tuple[0];
            let value = &tuple[1];

            if tag.is_atom_eq("set") {
                // {set, N} -> set to N, return old value
                if let Some(n) = value.as_integer() {
                    (Term::integer(current), n)
                } else {
                    (
                        Term::tuple2(Term::atom("error"), Term::atom("bad_value")),
                        current,
                    )
                }
            } else if tag.is_atom_eq("add") {
                // {add, N} -> add N, return new value
                if let Some(n) = value.as_integer() {
                    let new_value = current + n;
                    (Term::integer(new_value), new_value)
                } else {
                    (
                        Term::tuple2(Term::atom("error"), Term::atom("bad_value")),
                        current,
                    )
                }
            } else {
                (
                    Term::tuple2(Term::atom("error"), Term::atom("unknown_request")),
                    current,
                )
            }
        } else {
            (
                Term::tuple2(Term::atom("error"), Term::atom("unknown_request")),
                current,
            )
        }
    } else {
        (
            Term::tuple2(Term::atom("error"), Term::atom("unknown_request")),
            current,
        )
    };

    let new_state = Term::integer(new_counter);
    let result = gen_wasmserver::call_reply(reply, new_state);

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
    let request_bytes = unsafe { read_etf_data(request_data, request_len) };
    let state_bytes = unsafe { read_etf_data(state_data, state_len) };

    // Decode current state
    let current = match etf::decode(state_bytes) {
        Ok(term) => decode_state(&term),
        Err(_) => 0,
    };

    // Decode request
    let request = match etf::decode(request_bytes) {
        Ok(term) => term,
        Err(_) => {
            let result = gen_wasmserver::noreply(Term::integer(current));
            return write_result(&result, result_data, result_len);
        }
    };

    // Handle different requests
    let new_counter = if request.is_atom_eq("increment") {
        current + 1
    } else if request.is_atom_eq("decrement") {
        current - 1
    } else if request.is_atom_eq("reset") {
        *INITIAL_VALUE.borrow()
    } else if let Some(tuple) = request.as_tuple() {
        if tuple.len() == 2 {
            let tag = &tuple[0];
            let value = &tuple[1];

            if tag.is_atom_eq("increment") {
                if let Some(n) = value.as_integer() {
                    current + n
                } else {
                    current
                }
            } else if tag.is_atom_eq("decrement") {
                if let Some(n) = value.as_integer() {
                    current - n
                } else {
                    current
                }
            } else if tag.is_atom_eq("multiply") {
                if let Some(n) = value.as_integer() {
                    current * n
                } else {
                    current
                }
            } else if tag.is_atom_eq("set") {
                // Also handle set as cast (just changes value, no return)
                if let Some(n) = value.as_integer() {
                    n
                } else {
                    current
                }
            } else {
                current
            }
        } else {
            current
        }
    } else {
        current
    };

    let new_state = Term::integer(new_counter);
    let result = gen_wasmserver::noreply(new_state);

    write_result(&result, result_data, result_len)
}

/// Handle info messages
///
/// For this simple server, we just ignore all info messages.
#[no_mangle]
pub extern "C" fn wasm_handle_info(
    _info_data: *const u8,
    _info_len: u32,
    state_data: *const u8,
    state_len: u32,
    result_data: *mut *mut u8,
    result_len: *mut u32,
) -> i32 {
    let state_bytes = unsafe { read_etf_data(state_data, state_len) };

    // Just pass through the state unchanged
    let current = match etf::decode(state_bytes) {
        Ok(term) => decode_state(&term),
        Err(_) => 0,
    };

    let new_state = Term::integer(current);
    let result = gen_wasmserver::noreply(new_state);

    write_result(&result, result_data, result_len)
}

/// Handle termination
///
/// Nothing to clean up for this simple server.
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
// Tests (for native builds)
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_etf_encode_decode_integer() {
        let term = Term::integer(42);
        let encoded = etf::encode(&term).unwrap();
        let decoded = etf::decode(&encoded).unwrap();
        assert_eq!(decoded.as_integer(), Some(42));
    }

    #[test]
    fn test_etf_encode_decode_atom() {
        let term = Term::atom("hello");
        let encoded = etf::encode(&term).unwrap();
        let decoded = etf::decode(&encoded).unwrap();
        assert_eq!(decoded.as_atom(), Some("hello"));
    }

    #[test]
    fn test_etf_encode_decode_tuple() {
        let term = Term::tuple2(Term::atom("ok"), Term::integer(123));
        let encoded = etf::encode(&term).unwrap();
        let decoded = etf::decode(&encoded).unwrap();

        assert!(decoded.is_tuple());
        assert_eq!(decoded.tuple_arity(), Some(2));
        assert!(decoded.tuple_element(0).unwrap().is_atom_eq("ok"));
        assert_eq!(decoded.tuple_element(1).unwrap().as_integer(), Some(123));
    }

    #[test]
    fn test_init_ok() {
        let state = Term::integer(0);
        let result = gen_wasmserver::init_ok(state);

        assert!(result.is_tuple());
        assert_eq!(result.tuple_arity(), Some(2));
        assert!(result.tuple_element(0).unwrap().is_atom_eq("ok"));
    }

    #[test]
    fn test_call_reply() {
        let reply = Term::integer(42);
        let state = Term::integer(100);
        let result = gen_wasmserver::call_reply(reply, state);

        assert!(result.is_tuple());
        assert_eq!(result.tuple_arity(), Some(3));
        assert!(result.tuple_element(0).unwrap().is_atom_eq("reply"));
    }
}
