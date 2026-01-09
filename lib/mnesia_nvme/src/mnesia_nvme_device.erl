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

%% @doc Unified interface to NVMe KV devices.
%%
%% This module provides a single interface that automatically selects
%% the appropriate backend:
%% - mnesia_nvme_nif: Real NVMe hardware via io_uring (Linux 5.19+)
%% - mnesia_nvme_mock: ETS-based mock for testing
%%
%% Selection is done automatically based on:
%% 1. Application environment: {mnesia_nvme, backend, mock | nif}
%% 2. Device availability: Falls back to mock if NIF fails
%%
-module(mnesia_nvme_device).

-export([open/1, close/1]).
-export([store/4, retrieve/3, delete/3, exists/3, list_keys/3]).
-export([info/1]).
-export([backend/0]).

-define(BACKEND_KEY, {?MODULE, backend}).

%% @doc Open an NVMe KV device.
%% Automatically selects NIF or mock based on availability.
-spec open(DevicePath :: string()) -> {ok, term()} | {error, term()}.
open(DevicePath) ->
    Backend = select_backend(),
    case Backend of
        nif ->
            case mnesia_nvme_nif:open(DevicePath) of
                {ok, Handle} ->
                    persistent_term:put(?BACKEND_KEY, nif),
                    {ok, {nif, Handle}};
                {error, _} = Error ->
                    %% Fall back to mock
                    case mnesia_nvme_mock:open(DevicePath) of
                        {ok, MockHandle} ->
                            persistent_term:put(?BACKEND_KEY, mock),
                            {ok, {mock, MockHandle}};
                        MockError ->
                            MockError
                    end
            end;
        mock ->
            case mnesia_nvme_mock:open(DevicePath) of
                {ok, Handle} ->
                    persistent_term:put(?BACKEND_KEY, mock),
                    {ok, {mock, Handle}};
                Error ->
                    Error
            end
    end.

%% @doc Close a device handle.
-spec close(Handle :: term()) -> ok | {error, term()}.
close({nif, Handle}) ->
    mnesia_nvme_nif:close(Handle);
close({mock, Handle}) ->
    mnesia_nvme_mock:close(Handle).

%% @doc Store a key-value pair.
-spec store(Handle :: term(), Namespace :: non_neg_integer(),
            Key :: binary(), Value :: binary()) -> ok | {error, term()}.
store({nif, Handle}, Namespace, Key, Value) ->
    mnesia_nvme_nif:store(Handle, Namespace, Key, Value);
store({mock, Handle}, Namespace, Key, Value) ->
    mnesia_nvme_mock:store(Handle, Namespace, Key, Value).

%% @doc Retrieve a value by key.
-spec retrieve(Handle :: term(), Namespace :: non_neg_integer(),
               Key :: binary()) -> {ok, binary()} | {error, term()}.
retrieve({nif, Handle}, Namespace, Key) ->
    mnesia_nvme_nif:retrieve(Handle, Namespace, Key);
retrieve({mock, Handle}, Namespace, Key) ->
    mnesia_nvme_mock:retrieve(Handle, Namespace, Key).

%% @doc Delete a key-value pair.
-spec delete(Handle :: term(), Namespace :: non_neg_integer(),
             Key :: binary()) -> ok | {error, term()}.
delete({nif, Handle}, Namespace, Key) ->
    mnesia_nvme_nif:delete(Handle, Namespace, Key);
delete({mock, Handle}, Namespace, Key) ->
    mnesia_nvme_mock:delete(Handle, Namespace, Key).

%% @doc Check if a key exists.
-spec exists(Handle :: term(), Namespace :: non_neg_integer(),
             Key :: binary()) -> boolean() | {error, term()}.
exists({nif, Handle}, Namespace, Key) ->
    mnesia_nvme_nif:exists(Handle, Namespace, Key);
exists({mock, Handle}, Namespace, Key) ->
    mnesia_nvme_mock:exists(Handle, Namespace, Key).

%% @doc List keys with optional prefix.
-spec list_keys(Handle :: term(), Namespace :: non_neg_integer(),
                Prefix :: binary()) -> {ok, [binary()]} | {error, term()}.
list_keys({nif, Handle}, Namespace, Prefix) ->
    mnesia_nvme_nif:list_keys(Handle, Namespace, Prefix);
list_keys({mock, Handle}, Namespace, Prefix) ->
    mnesia_nvme_mock:list_keys(Handle, Namespace, Prefix).

%% @doc Get device info.
-spec info(Handle :: term()) -> {ok, map()} | {error, term()}.
info({nif, Handle}) ->
    mnesia_nvme_nif:info(Handle);
info({mock, Handle}) ->
    mnesia_nvme_mock:info(Handle).

%% @doc Get current backend in use.
-spec backend() -> nif | mock | undefined.
backend() ->
    persistent_term:get(?BACKEND_KEY, undefined).

%%====================================================================
%% Internal functions
%%====================================================================

select_backend() ->
    case application:get_env(mnesia_nvme, backend) of
        {ok, Backend} when Backend =:= nif; Backend =:= mock ->
            Backend;
        _ ->
            %% Auto-select: try NIF first, fall back to mock
            case code:which(mnesia_nvme_nif) of
                non_existing -> mock;
                _ ->
                    %% NIF module exists, but check if it's actually loaded
                    case erlang:function_exported(mnesia_nvme_nif, open, 1) of
                        true -> nif;
                        false -> mock
                    end
            end
    end.
