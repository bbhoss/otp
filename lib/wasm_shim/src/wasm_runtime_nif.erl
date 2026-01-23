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
%% @doc NIF interface for WebAssembly runtime integration using wasmtime.
%% @end
-module(wasm_runtime_nif).

%% Avoid clash with erlang:load_module/2
-compile({no_auto_import, [load_module/2]}).

-export([load_module/1,
         load_module/2,
         unload_module/1,
         call_function/3,
         call_function/4,
         get_exports/1,
         get_memory/2,
         get_memory/3,
         set_memory/3,
         validate_module/1]).

-export_type([wasm_ref/0,
              wasm_error/0,
              export_map/0,
              call_options/0]).

-on_load(init/0).

%% Types
-opaque wasm_ref() :: reference().
-type wasm_error() :: {error, atom() | {atom(), term()}}.
-type export_map() :: #{atom() => arity()}.
-type call_options() :: #{
    timeout => timeout(),
    fuel => non_neg_integer()
}.

%% NIF Loading
-spec init() -> ok | {error, term()}.
init() ->
    PrivDir = case code:priv_dir(wasm_shim) of
        {error, bad_name} ->
            case filelib:is_dir("priv") of
                true -> "priv";
                false -> "../priv"
            end;
        Dir -> Dir
    end,
    SoName = filename:join(PrivDir, "wasm_runtime_nif"),
    case erlang:load_nif(SoName, 0) of
        ok -> ok;
        {error, {reload, _}} -> ok;
        {error, Reason} ->
            error({nif_load_failed, Reason})
    end.

%% Public API

-spec load_module(WasmBinary :: binary()) ->
    {ok, wasm_ref(), export_map()} | wasm_error().
load_module(WasmBinary) ->
    load_module(WasmBinary, #{}).

-spec load_module(WasmBinary :: binary(), Options :: map()) ->
    {ok, wasm_ref(), export_map()} | wasm_error().
load_module(WasmBinary, Options) when is_binary(WasmBinary), is_map(Options) ->
    load_module_nif(WasmBinary, Options);
load_module(WasmBinary, Options) ->
    error(badarg, [WasmBinary, Options]).

-spec unload_module(wasm_ref()) -> ok.
unload_module(Ref) when is_reference(Ref) ->
    unload_module_nif(Ref);
unload_module(Ref) ->
    error(badarg, [Ref]).

-spec call_function(wasm_ref(), atom(), [binary()]) ->
    {ok, binary()} | wasm_error().
call_function(Ref, Function, Args) ->
    call_function(Ref, Function, Args, #{}).

-spec call_function(wasm_ref(), atom(), [binary()], call_options()) ->
    {ok, binary()} | wasm_error().
call_function(Ref, Function, Args, Options)
  when is_reference(Ref), is_atom(Function), is_list(Args), is_map(Options) ->
    call_function_nif(Ref, Function, Args, Options);
call_function(Ref, Function, Args, Options) ->
    error(badarg, [Ref, Function, Args, Options]).

-spec get_exports(wasm_ref()) -> {ok, export_map()} | wasm_error().
get_exports(Ref) when is_reference(Ref) ->
    get_exports_nif(Ref);
get_exports(Ref) ->
    error(badarg, [Ref]).

-spec get_memory(wasm_ref(), non_neg_integer(), non_neg_integer()) ->
    {ok, binary()} | wasm_error().
get_memory(Ref, Offset, Length) when is_reference(Ref), is_integer(Offset), is_integer(Length) ->
    get_memory_nif(Ref, {Offset, Length});
get_memory(Ref, Offset, Length) ->
    error(badarg, [Ref, Offset, Length]).

-spec get_memory(wasm_ref(), {non_neg_integer(), non_neg_integer()}) ->
    {ok, binary()} | wasm_error().
get_memory(Ref, {Offset, Length}) ->
    get_memory(Ref, Offset, Length).

-spec set_memory(wasm_ref(), non_neg_integer(), binary()) -> ok | wasm_error().
set_memory(Ref, Offset, Data) when is_reference(Ref), is_integer(Offset), is_binary(Data) ->
    set_memory_nif(Ref, Offset, Data);
set_memory(Ref, Offset, Data) ->
    error(badarg, [Ref, Offset, Data]).

-spec validate_module(binary()) -> ok | wasm_error().
validate_module(WasmBinary) when is_binary(WasmBinary) ->
    validate_module_nif(WasmBinary);
validate_module(WasmBinary) ->
    error(badarg, [WasmBinary]).

%% NIF stubs - these are replaced when the NIF loads
load_module_nif(_WasmBinary, _Options) ->
    erlang:nif_error(nif_not_loaded).

unload_module_nif(_Ref) ->
    erlang:nif_error(nif_not_loaded).

call_function_nif(_Ref, _Function, _Args, _Options) ->
    erlang:nif_error(nif_not_loaded).

get_exports_nif(_Ref) ->
    erlang:nif_error(nif_not_loaded).

get_memory_nif(_Ref, _OffsetLength) ->
    erlang:nif_error(nif_not_loaded).

set_memory_nif(_Ref, _Offset, _Data) ->
    erlang:nif_error(nif_not_loaded).

validate_module_nif(_WasmBinary) ->
    erlang:nif_error(nif_not_loaded).
