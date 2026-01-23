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
-module(wasm_runtime_nif).
-moduledoc """
NIF interface for WebAssembly runtime integration.

This module provides the native interface to a WebAssembly runtime
(such as wasmtime or wasmer) for executing WASM code within the
Erlang VM.

The module is used internally by `gen_wasmserver` to:
- Load and validate WASM modules
- Create and manage WASM instances
- Call exported WASM functions
- Manage WASM memory

## Runtime Selection

The WASM runtime backend can be selected at compile time. Currently
supported backends:
- `wasmtime` (default) - Bytecode Alliance's wasmtime
- `wasmer` - Wasmer runtime

## Memory Management

WASM instances are managed using Erlang NIF resources, which ensures
proper cleanup when the owning process terminates. The WASM linear
memory is accessible to the host for data exchange via ETF encoding.

## Thread Safety

Each WASM instance is isolated and can only be accessed from a single
Erlang process at a time. The NIF uses dirty schedulers for long-running
WASM function calls to avoid blocking regular schedulers.

## See Also

`m:gen_wasmserver` for the high-level server behavior.
""".

-export([load_module/1,
         load_module/2,
         unload_module/1,
         call_function/3,
         call_function/4,
         get_exports/1,
         get_memory/1,
         set_memory/3,
         validate_module/1]).

-export_type([wasm_ref/0,
              wasm_error/0,
              export_map/0,
              call_options/0]).

-on_load(init/0).

%% NIF loading
-nifs([load_module_nif/2,
       unload_module_nif/1,
       call_function_nif/4,
       get_exports_nif/1,
       get_memory_nif/2,
       set_memory_nif/3,
       validate_module_nif/1]).

%% ===================================================================
%% Types
%% ===================================================================

-doc "Opaque reference to a loaded WASM module instance.".
-opaque wasm_ref() :: reference().

-doc "Error returned from WASM operations.".
-type wasm_error() :: {error, atom() | {atom(), term()}}.

-doc "Map of exported function names to their arities.".
-type export_map() :: #{atom() => arity()}.

-doc "Options for WASM function calls.".
-type call_options() :: #{
    timeout => timeout(),
    fuel => non_neg_integer()  %% Fuel limit for wasmtime
}.

%% ===================================================================
%% NIF Loading
%% ===================================================================

-spec init() -> ok | {error, term()}.
init() ->
    %% Try to load the NIF library
    SoName = case code:priv_dir(wasm_shim) of
        {error, bad_name} ->
            %% Not installed as application, try local path
            case filelib:is_dir("priv") of
                true ->
                    "priv/wasm_runtime_nif";
                false ->
                    filename:join(["..", "priv", "wasm_runtime_nif"])
            end;
        Dir ->
            filename:join(Dir, "wasm_runtime_nif")
    end,
    case erlang:load_nif(SoName, 0) of
        ok -> ok;
        {error, {reload, _}} -> ok;
        {error, _} = Error ->
            %% NIF not available, use fallback (stub) implementation
            logger:warning("WASM NIF not loaded: ~p. Using stub implementation.", [Error]),
            ok
    end.

%% ===================================================================
%% Public API
%% ===================================================================

-doc """
Load a WASM module from binary data.

Validates, compiles, and instantiates a WASM module. Returns a reference
that can be used to call exported functions.

## Arguments
- `WasmBinary` - The compiled WASM module in binary format

## Returns
- `{ok, Ref, Exports}` on success where:
  - `Ref` is an opaque reference to the instance
  - `Exports` is a map of exported function names to arities
- `{error, Reason}` on failure

## Example
```erlang
{ok, Binary} = file:read_file("my_module.wasm"),
{ok, Ref, Exports} = wasm_runtime_nif:load_module(Binary),
%% Exports = #{wasm_init => 1, wasm_handle_call => 3, ...}
```
""".
-spec load_module(WasmBinary :: binary()) ->
    {ok, wasm_ref(), export_map()} | wasm_error().
load_module(WasmBinary) ->
    load_module(WasmBinary, #{}).

-doc """
Load a WASM module with options.

Same as `load_module/1` but with additional configuration options.

## Options
- `imports` - Map of host function imports
- `memory_pages` - Initial memory pages (64KB each)
- `max_memory_pages` - Maximum memory pages
- `fuel` - Initial fuel amount (wasmtime only)

## Example
```erlang
{ok, Ref, _} = wasm_runtime_nif:load_module(Binary, #{
    memory_pages => 256,
    max_memory_pages => 1024
}).
```
""".
-spec load_module(WasmBinary :: binary(), Options :: map()) ->
    {ok, wasm_ref(), export_map()} | wasm_error().
load_module(WasmBinary, Options) when is_binary(WasmBinary), is_map(Options) ->
    load_module_nif(WasmBinary, Options);
load_module(WasmBinary, Options) ->
    error(badarg, [WasmBinary, Options]).

-doc """
Unload a WASM module and free resources.

After calling this function, the reference is no longer valid.
""".
-spec unload_module(wasm_ref()) -> ok.
unload_module(Ref) when is_reference(Ref) ->
    unload_module_nif(Ref);
unload_module(Ref) ->
    error(badarg, [Ref]).

-doc """
Call an exported function in the WASM module.

## Arguments
- `Ref` - Reference to the loaded WASM module
- `Function` - Name of the exported function (atom)
- `Args` - List of binary arguments (ETF encoded)

## Returns
- `{ok, Result}` where Result is the ETF-encoded return value
- `{error, Reason}` on failure

## Example
```erlang
Args = term_to_binary(my_argument),
{ok, ResultBin} = wasm_runtime_nif:call_function(Ref, wasm_init, [Args]),
Result = binary_to_term(ResultBin).
```
""".
-spec call_function(wasm_ref(), atom(), [binary()]) ->
    {ok, binary()} | wasm_error().
call_function(Ref, Function, Args) ->
    call_function(Ref, Function, Args, #{}).

-doc """
Call an exported function with options.

Same as `call_function/3` but with additional options.

## Options
- `timeout` - Call timeout in milliseconds
- `fuel` - Fuel limit for this call (wasmtime)
""".
-spec call_function(wasm_ref(), atom(), [binary()], call_options()) ->
    {ok, binary()} | wasm_error().
call_function(Ref, Function, Args, Options)
  when is_reference(Ref), is_atom(Function), is_list(Args), is_map(Options) ->
    call_function_nif(Ref, Function, Args, Options);
call_function(Ref, Function, Args, Options) ->
    error(badarg, [Ref, Function, Args, Options]).

-doc """
Get the map of exported functions from a WASM module.

Returns a map where keys are function names (atoms) and values
are their arities.
""".
-spec get_exports(wasm_ref()) -> {ok, export_map()} | wasm_error().
get_exports(Ref) when is_reference(Ref) ->
    get_exports_nif(Ref);
get_exports(Ref) ->
    error(badarg, [Ref]).

-doc """
Read data from WASM linear memory.

## Arguments
- `Ref` - Reference to the loaded WASM module
- `Offset` - Byte offset into linear memory
- `Length` - Number of bytes to read

## Returns
- `{ok, Binary}` containing the memory contents
- `{error, Reason}` if the read is out of bounds
""".
-spec get_memory(wasm_ref(), non_neg_integer(), non_neg_integer()) ->
    {ok, binary()} | wasm_error().
get_memory(Ref, Offset, Length) when is_reference(Ref), is_integer(Offset), is_integer(Length) ->
    get_memory_nif(Ref, {Offset, Length});
get_memory(Ref, Offset, Length) ->
    error(badarg, [Ref, Offset, Length]).

-doc "Get memory with only offset and length tuple.".
-spec get_memory(wasm_ref(), {non_neg_integer(), non_neg_integer()}) ->
    {ok, binary()} | wasm_error().
get_memory(Ref, {Offset, Length}) ->
    get_memory(Ref, Offset, Length).

-doc """
Write data to WASM linear memory.

## Arguments
- `Ref` - Reference to the loaded WASM module
- `Offset` - Byte offset into linear memory
- `Data` - Binary data to write

## Returns
- `ok` on success
- `{error, Reason}` if the write is out of bounds
""".
-spec set_memory(wasm_ref(), non_neg_integer(), binary()) -> ok | wasm_error().
set_memory(Ref, Offset, Data) when is_reference(Ref), is_integer(Offset), is_binary(Data) ->
    set_memory_nif(Ref, Offset, Data);
set_memory(Ref, Offset, Data) ->
    error(badarg, [Ref, Offset, Data]).

-doc """
Validate a WASM binary without loading it.

Checks if the binary is a valid WASM module and reports any errors.
Does not create an instance.

## Returns
- `ok` if the module is valid
- `{error, Reason}` with validation errors
""".
-spec validate_module(binary()) -> ok | wasm_error().
validate_module(WasmBinary) when is_binary(WasmBinary) ->
    validate_module_nif(WasmBinary);
validate_module(WasmBinary) ->
    error(badarg, [WasmBinary]).

%% ===================================================================
%% NIF Stubs (fallback implementation)
%% ===================================================================

%% These functions are replaced by the NIF when loaded.
%% They provide a minimal stub implementation for testing.

-spec load_module_nif(binary(), map()) ->
    {ok, reference(), map()} | {error, term()}.
load_module_nif(WasmBinary, _Options) ->
    %% Stub: create a reference and detect exports from WASM header
    case validate_wasm_header(WasmBinary) of
        ok ->
            Ref = make_ref(),
            %% Store the module data in process dictionary for stub
            put({wasm_module, Ref}, WasmBinary),
            Exports = detect_stub_exports(),
            {ok, Ref, Exports};
        {error, _} = Error ->
            Error
    end.

-spec unload_module_nif(reference()) -> ok.
unload_module_nif(Ref) ->
    %% Stub: remove from process dictionary
    erase({wasm_module, Ref}),
    ok.

-spec call_function_nif(reference(), atom(), [binary()], map()) ->
    {ok, binary()} | {error, term()}.
call_function_nif(Ref, Function, Args, _Options) ->
    %% Stub: simulate WASM function calls
    case get({wasm_module, Ref}) of
        undefined ->
            {error, invalid_reference};
        _WasmBinary ->
            stub_call_function(Function, Args)
    end.

-spec get_exports_nif(reference()) -> {ok, map()} | {error, term()}.
get_exports_nif(Ref) ->
    case get({wasm_module, Ref}) of
        undefined ->
            {error, invalid_reference};
        _WasmBinary ->
            {ok, detect_stub_exports()}
    end.

-spec get_memory_nif(reference(), {non_neg_integer(), non_neg_integer()}) ->
    {ok, binary()} | {error, term()}.
get_memory_nif(Ref, {_Offset, Length}) ->
    case get({wasm_module, Ref}) of
        undefined ->
            {error, invalid_reference};
        _WasmBinary ->
            %% Stub: return zeros
            {ok, <<0:(Length*8)>>}
    end.

-spec set_memory_nif(reference(), non_neg_integer(), binary()) ->
    ok | {error, term()}.
set_memory_nif(Ref, _Offset, _Data) ->
    case get({wasm_module, Ref}) of
        undefined ->
            {error, invalid_reference};
        _WasmBinary ->
            ok
    end.

-spec validate_module_nif(binary()) -> ok | {error, term()}.
validate_module_nif(WasmBinary) ->
    validate_wasm_header(WasmBinary).

%% ===================================================================
%% Internal Helper Functions
%% ===================================================================

-spec validate_wasm_header(binary()) -> ok | {error, term()}.
validate_wasm_header(<<16#00, 16#61, 16#73, 16#6D, Version:32/little, _/binary>>)
  when Version >= 1 ->
    ok;
validate_wasm_header(<<16#00, 16#61, 16#73, 16#6D, Version:32/little, _/binary>>) ->
    {error, {unsupported_version, Version}};
validate_wasm_header(<<>>) ->
    {error, empty_module};
validate_wasm_header(_) ->
    {error, invalid_magic}.

-spec detect_stub_exports() -> export_map().
detect_stub_exports() ->
    %% Standard gen_wasmserver exports expected
    #{wasm_init => 1,
      wasm_handle_call => 3,
      wasm_handle_cast => 2,
      wasm_handle_info => 2,
      wasm_terminate => 2}.

-spec stub_call_function(atom(), [binary()]) -> {ok, binary()} | {error, term()}.
stub_call_function(wasm_init, [ArgsEncoded]) ->
    %% Stub: return {ok, Args} as initial state
    try binary_to_term(ArgsEncoded) of
        Args ->
            Result = {ok, Args},
            {ok, term_to_binary(Result)}
    catch
        _:_ ->
            {error, decode_failed}
    end;
stub_call_function(wasm_handle_call, [RequestEncoded, _FromEncoded, StateEncoded]) ->
    %% Stub: echo the request back as reply
    try
        Request = binary_to_term(RequestEncoded),
        State = binary_to_term(StateEncoded),
        Result = {reply, {echo, Request}, State},
        {ok, term_to_binary(Result)}
    catch
        _:_ ->
            {error, decode_failed}
    end;
stub_call_function(wasm_handle_cast, [_RequestEncoded, StateEncoded]) ->
    %% Stub: just return state unchanged
    try
        State = binary_to_term(StateEncoded),
        Result = {noreply, State},
        {ok, term_to_binary(Result)}
    catch
        _:_ ->
            {error, decode_failed}
    end;
stub_call_function(wasm_handle_info, [_InfoEncoded, StateEncoded]) ->
    %% Stub: just return state unchanged
    try
        State = binary_to_term(StateEncoded),
        Result = {noreply, State},
        {ok, term_to_binary(Result)}
    catch
        _:_ ->
            {error, decode_failed}
    end;
stub_call_function(wasm_terminate, [_ReasonEncoded, _StateEncoded]) ->
    {ok, term_to_binary(ok)};
stub_call_function(Function, _Args) ->
    {error, {unknown_function, Function}}.
