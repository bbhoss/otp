//! gen_wasmserver helpers for Rust WASM components.
//!
//! This module provides convenient functions for building the response
//! tuples expected by gen_wasmserver callbacks.

use crate::etf::{self, Term};
use alloc::vec::Vec;

/// Build an {ok, State} init result
pub fn init_ok(state: Term) -> Term {
    Term::tuple2(Term::atom("ok"), state)
}

/// Build an {ok, State, Timeout} init result
pub fn init_ok_timeout(state: Term, timeout_ms: u32) -> Term {
    Term::tuple3(Term::atom("ok"), state, Term::integer(timeout_ms as i64))
}

/// Build an {ok, State, hibernate} init result
pub fn init_ok_hibernate(state: Term) -> Term {
    Term::tuple3(Term::atom("ok"), state, Term::atom("hibernate"))
}

/// Build a {stop, Reason} init result
pub fn init_stop(reason: Term) -> Term {
    Term::tuple2(Term::atom("stop"), reason)
}

/// Build an ignore init result
pub fn init_ignore() -> Term {
    Term::atom("ignore")
}

/// Build a {reply, Reply, NewState} call result
pub fn call_reply(reply: Term, new_state: Term) -> Term {
    Term::tuple3(Term::atom("reply"), reply, new_state)
}

/// Build a {reply, Reply, NewState, Timeout} call result
pub fn call_reply_timeout(reply: Term, new_state: Term, timeout_ms: u32) -> Term {
    Term::tuple4(
        Term::atom("reply"),
        reply,
        new_state,
        Term::integer(timeout_ms as i64),
    )
}

/// Build a {reply, Reply, NewState, hibernate} call result
pub fn call_reply_hibernate(reply: Term, new_state: Term) -> Term {
    Term::tuple4(
        Term::atom("reply"),
        reply,
        new_state,
        Term::atom("hibernate"),
    )
}

/// Build a {noreply, NewState} result
pub fn noreply(new_state: Term) -> Term {
    Term::tuple2(Term::atom("noreply"), new_state)
}

/// Build a {noreply, NewState, Timeout} result
pub fn noreply_timeout(new_state: Term, timeout_ms: u32) -> Term {
    Term::tuple3(
        Term::atom("noreply"),
        new_state,
        Term::integer(timeout_ms as i64),
    )
}

/// Build a {noreply, NewState, hibernate} result
pub fn noreply_hibernate(new_state: Term) -> Term {
    Term::tuple3(Term::atom("noreply"), new_state, Term::atom("hibernate"))
}

/// Build a {stop, Reason, Reply, NewState} call result
pub fn call_stop_reply(reason: Term, reply: Term, new_state: Term) -> Term {
    Term::tuple4(Term::atom("stop"), reason, reply, new_state)
}

/// Build a {stop, Reason, NewState} result
pub fn stop(reason: Term, new_state: Term) -> Term {
    Term::tuple3(Term::atom("stop"), reason, new_state)
}

/// Encode a result term to ETF bytes
pub fn encode_result(term: &Term) -> Result<Vec<u8>, etf::Error> {
    etf::encode(term)
}

/// Decode a request from ETF bytes
pub fn decode_request(data: &[u8]) -> Result<Term, etf::Error> {
    etf::decode(data)
}
