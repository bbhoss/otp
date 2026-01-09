%%
%% Copyright Ericsson AB 2025. All Rights Reserved.
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

%% @doc NIF interface to NVMe Key-Value operations via io_uring passthrough.
%%
%% This module provides low-level access to NVMe KV command set operations
%% using the Linux io_uring passthrough interface on NVMe character devices.
%%
%% The NVMe KV command set (CSI 0x01) provides:
%% - Store (0x01): Store a key-value pair
%% - Retrieve (0x02): Get value by key
%% - Delete (0x10): Remove a key-value pair
%% - Exist (0x14): Check if key exists
%% - List (0x06): Iterate over keys
%%
-module(mnesia_nvme_nif).

-export([open/1, close/1]).
-export([store/4, retrieve/3, delete/3, exists/3, list_keys/3]).
-export([info/1]).

-on_load(init/0).

-define(APPNAME, mnesia_nvme).
-define(LIBNAME, mnesia_nvme_nif).

%% @doc Initialize the NIF library.
init() ->
    SoName = case code:priv_dir(?APPNAME) of
        {error, bad_name} ->
            case filelib:is_dir(filename:join(["..", priv])) of
                true ->
                    filename:join(["..", priv, ?LIBNAME]);
                _ ->
                    filename:join([priv, ?LIBNAME])
            end;
        Dir ->
            filename:join(Dir, ?LIBNAME)
    end,
    erlang:load_nif(SoName, 0).

%% @doc Open an NVMe KV device.
%% DevicePath should be the NVMe generic char device (e.g., "/dev/ng0n1").
%% Returns {ok, Handle} or {error, Reason}.
-spec open(DevicePath :: string()) -> {ok, reference()} | {error, term()}.
open(_DevicePath) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Close an NVMe KV device handle.
-spec close(Handle :: reference()) -> ok | {error, term()}.
close(_Handle) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Store a key-value pair.
%% Namespace is typically 1.
-spec store(Handle :: reference(), Namespace :: non_neg_integer(),
            Key :: binary(), Value :: binary()) -> ok | {error, term()}.
store(_Handle, _Namespace, _Key, _Value) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Retrieve a value by key.
%% Returns {ok, Value} or {error, not_found} or {error, Reason}.
-spec retrieve(Handle :: reference(), Namespace :: non_neg_integer(),
               Key :: binary()) -> {ok, binary()} | {error, term()}.
retrieve(_Handle, _Namespace, _Key) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Delete a key-value pair.
-spec delete(Handle :: reference(), Namespace :: non_neg_integer(),
             Key :: binary()) -> ok | {error, term()}.
delete(_Handle, _Namespace, _Key) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Check if a key exists.
-spec exists(Handle :: reference(), Namespace :: non_neg_integer(),
             Key :: binary()) -> boolean() | {error, term()}.
exists(_Handle, _Namespace, _Key) ->
    erlang:nif_error(nif_not_loaded).

%% @doc List keys with optional prefix.
%% Returns {ok, [Key]} or {error, Reason}.
-spec list_keys(Handle :: reference(), Namespace :: non_neg_integer(),
                Prefix :: binary()) -> {ok, [binary()]} | {error, term()}.
list_keys(_Handle, _Namespace, _Prefix) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Get device info.
-spec info(Handle :: reference()) -> {ok, map()} | {error, term()}.
info(_Handle) ->
    erlang:nif_error(nif_not_loaded).
