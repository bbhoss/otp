%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2024-2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
-module(rust_counter_example).
-compile({no_auto_import, [get/1]}).
-moduledoc false.

-export([start/0, start/1, start_link/0, start_link/1, stop/1]).
-export([get/1, set/2, add/2]).
-export([increment/1, increment/2, decrement/1, decrement/2]).
-export([multiply/2, reset/1]).

%% Demo function
-export([demo/0]).

%% ===================================================================
%% API Functions
%% ===================================================================


-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    start(0).


-spec start(InitialValue :: integer()) -> {ok, pid()} | {error, term()}.
start(InitialValue) when is_integer(InitialValue) ->
    case load_wasm_binary() of
        {ok, WasmBinary} ->
            gen_wasmserver:start(WasmBinary, InitialValue, []);
        {error, _} = Error ->
            Error
    end.


-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(0).


-spec start_link(InitialValue :: integer()) -> {ok, pid()} | {error, term()}.
start_link(InitialValue) when is_integer(InitialValue) ->
    case load_wasm_binary() of
        {ok, WasmBinary} ->
            gen_wasmserver:start_link(WasmBinary, InitialValue, []);
        {error, _} = Error ->
            Error
    end.


-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_wasmserver:stop(Pid).

%% -------------------------------------------------------------------
%% Synchronous Operations (calls)
%% -------------------------------------------------------------------


-spec get(pid()) -> integer().
get(Pid) ->
    gen_wasmserver:call(Pid, get).


-spec set(pid(), integer()) -> integer().
set(Pid, Value) when is_integer(Value) ->
    gen_wasmserver:call(Pid, {set, Value}).


-spec add(pid(), integer()) -> integer().
add(Pid, N) when is_integer(N) ->
    gen_wasmserver:call(Pid, {add, N}).

%% -------------------------------------------------------------------
%% Asynchronous Operations (casts)
%% -------------------------------------------------------------------


-spec increment(pid()) -> ok.
increment(Pid) ->
    gen_wasmserver:cast(Pid, increment).


-spec increment(pid(), integer()) -> ok.
increment(Pid, N) when is_integer(N) ->
    gen_wasmserver:cast(Pid, {increment, N}).


-spec decrement(pid()) -> ok.
decrement(Pid) ->
    gen_wasmserver:cast(Pid, decrement).


-spec decrement(pid(), integer()) -> ok.
decrement(Pid, N) when is_integer(N) ->
    gen_wasmserver:cast(Pid, {decrement, N}).


-spec multiply(pid(), integer()) -> ok.
multiply(Pid, N) when is_integer(N) ->
    gen_wasmserver:cast(Pid, {multiply, N}).


-spec reset(pid()) -> ok.
reset(Pid) ->
    gen_wasmserver:cast(Pid, reset).

%% ===================================================================
%% Demo Function
%% ===================================================================


-spec demo() -> ok.
demo() ->
    io:format("~n=== Rust Counter Server Demo ===~n~n"),

    %% Start the server
    io:format("Starting Rust counter server with initial value 5...~n"),
    {ok, Pid} = start(5),
    io:format("  Started with pid ~p~n~n", [Pid]),

    %% Get initial value
    io:format("Getting current value...~n"),
    Value0 = get(Pid),
    io:format("  Current value: ~p~n~n", [Value0]),

    %% Increment
    io:format("Incrementing by 1...~n"),
    ok = increment(Pid),
    timer:sleep(10),
    Value1 = get(Pid),
    io:format("  Value after increment: ~p~n~n", [Value1]),

    %% Use atomic add (Rust feature)
    io:format("Adding 10 atomically (returns new value)...~n"),
    NewValue = add(Pid, 10),
    io:format("  New value returned: ~p~n~n", [NewValue]),

    %% Multiply (Rust-specific feature)
    io:format("Multiplying by 2...~n"),
    ok = multiply(Pid, 2),
    timer:sleep(10),
    Value2 = get(Pid),
    io:format("  Value after multiply: ~p~n~n", [Value2]),

    %% Decrement
    io:format("Decrementing by 5...~n"),
    ok = decrement(Pid, 5),
    timer:sleep(10),
    Value3 = get(Pid),
    io:format("  Value after decrement(5): ~p~n~n", [Value3]),

    %% Set
    io:format("Setting value to 1000...~n"),
    OldValue = set(Pid, 1000),
    io:format("  Old value was: ~p~n", [OldValue]),
    Value4 = get(Pid),
    io:format("  New value: ~p~n~n", [Value4]),

    %% Reset
    io:format("Resetting to initial value (5)...~n"),
    ok = reset(Pid),
    timer:sleep(10),
    Value5 = get(Pid),
    io:format("  Value after reset: ~p~n~n", [Value5]),

    %% Stop
    io:format("Stopping server...~n"),
    ok = stop(Pid),
    io:format("  Server stopped~n~n"),

    io:format("=== Demo Complete ===~n~n"),
    ok.

%% ===================================================================
%% Internal Functions
%% ===================================================================

-spec load_wasm_binary() -> {ok, binary()} | {error, term()}.
load_wasm_binary() ->
    %% Try to find the Rust WASM binary in various locations
    Paths = [
        "rust_counter.wasm",
        "rust_counter/target/wasm32-unknown-unknown/release/rust_counter.wasm",
        "rust_counter/target/wasm32-wasi/release/rust_counter.wasm",
        "../examples/rust_counter/target/wasm32-unknown-unknown/release/rust_counter.wasm",
        filename:join([code:priv_dir(wasm_shim), "examples", "rust_counter.wasm"]),
        filename:join([code:lib_dir(wasm_shim), "examples", "rust_counter.wasm"])
    ],
    find_wasm_file(Paths).

find_wasm_file([]) ->
    %% No WASM file found, create a minimal stub WASM binary for testing
    io:format("Warning: No Rust WASM file found, using stub implementation~n"),
    io:format("  Build with: cd rust_counter && cargo build --release --target wasm32-unknown-unknown~n"),
    {ok, create_stub_wasm()};
find_wasm_file([Path | Rest]) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            io:format("Loaded Rust WASM from: ~s~n", [Path]),
            {ok, Binary};
        {error, _} ->
            find_wasm_file(Rest)
    end.

%% Create a minimal valid WASM binary for testing
create_stub_wasm() ->
    <<
        16#00, 16#61, 16#73, 16#6D,  %% WASM magic number: \0asm
        16#01, 16#00, 16#00, 16#00   %% Version 1 (little-endian)
    >>.
