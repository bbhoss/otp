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

%% @doc Mock implementation of NVMe KV operations for testing.
%%
%% This module provides an ETS-based simulation of NVMe KV SSD behavior.
%% It implements the same interface as mnesia_nvme_nif but stores data
%% in ETS tables instead of actual NVMe hardware.
%%
%% Use this module for:
%% - Development and testing without NVMe hardware
%% - Unit testing the Mnesia backend
%% - Understanding the API before deploying to real hardware
%%
%% The mock simulates:
%% - Key size limits (1-255 bytes)
%% - Value size limits (up to 2MB)
%% - Key existence checking
%% - Key iteration with prefix filtering
%%
-module(mnesia_nvme_mock).

-behaviour(gen_server).

%% API (compatible with mnesia_nvme_nif)
-export([open/1, close/1]).
-export([store/4, retrieve/3, delete/3, exists/3, list_keys/3]).
-export([info/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_KEY_SIZE, 255).
-define(MAX_VALUE_SIZE, 2097152).  % 2MB

-record(state, {
    device_path :: string(),
    table :: ets:tid(),
    stats :: map()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Open a mock NVMe KV device.
%% DevicePath is used as a namespace identifier.
-spec open(DevicePath :: string()) -> {ok, pid()} | {error, term()}.
open(DevicePath) ->
    gen_server:start(?MODULE, [DevicePath], []).

%% @doc Close a mock device handle.
-spec close(Handle :: pid()) -> ok | {error, term()}.
close(Handle) ->
    gen_server:call(Handle, close).

%% @doc Store a key-value pair.
-spec store(Handle :: pid(), Namespace :: non_neg_integer(),
            Key :: binary(), Value :: binary()) -> ok | {error, term()}.
store(Handle, Namespace, Key, Value) ->
    gen_server:call(Handle, {store, Namespace, Key, Value}).

%% @doc Retrieve a value by key.
-spec retrieve(Handle :: pid(), Namespace :: non_neg_integer(),
               Key :: binary()) -> {ok, binary()} | {error, term()}.
retrieve(Handle, Namespace, Key) ->
    gen_server:call(Handle, {retrieve, Namespace, Key}).

%% @doc Delete a key-value pair.
-spec delete(Handle :: pid(), Namespace :: non_neg_integer(),
             Key :: binary()) -> ok | {error, term()}.
delete(Handle, Namespace, Key) ->
    gen_server:call(Handle, {delete, Namespace, Key}).

%% @doc Check if a key exists.
-spec exists(Handle :: pid(), Namespace :: non_neg_integer(),
             Key :: binary()) -> boolean() | {error, term()}.
exists(Handle, Namespace, Key) ->
    gen_server:call(Handle, {exists, Namespace, Key}).

%% @doc List keys with optional prefix.
-spec list_keys(Handle :: pid(), Namespace :: non_neg_integer(),
                Prefix :: binary()) -> {ok, [binary()]} | {error, term()}.
list_keys(Handle, Namespace, Prefix) ->
    gen_server:call(Handle, {list_keys, Namespace, Prefix}).

%% @doc Get device info.
-spec info(Handle :: pid()) -> {ok, map()} | {error, term()}.
info(Handle) ->
    gen_server:call(Handle, info).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([DevicePath]) ->
    Table = ets:new(nvme_kv_mock, [set, private]),
    State = #state{
        device_path = DevicePath,
        table = Table,
        stats = #{
            stores => 0,
            retrieves => 0,
            deletes => 0,
            bytes_written => 0,
            bytes_read => 0
        }
    },
    {ok, State}.

handle_call({store, Namespace, Key, Value}, _From, State) ->
    #state{table = Table, stats = Stats} = State,

    %% Validate key and value sizes
    case validate_kv(Key, Value) of
        ok ->
            FullKey = {Namespace, Key},
            ets:insert(Table, {FullKey, Value}),
            NewStats = Stats#{
                stores := maps:get(stores, Stats) + 1,
                bytes_written := maps:get(bytes_written, Stats) + byte_size(Value)
            },
            {reply, ok, State#state{stats = NewStats}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({retrieve, Namespace, Key}, _From, State) ->
    #state{table = Table, stats = Stats} = State,
    FullKey = {Namespace, Key},

    case ets:lookup(Table, FullKey) of
        [{_, Value}] ->
            NewStats = Stats#{
                retrieves := maps:get(retrieves, Stats) + 1,
                bytes_read := maps:get(bytes_read, Stats) + byte_size(Value)
            },
            {reply, {ok, Value}, State#state{stats = NewStats}};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({delete, Namespace, Key}, _From, State) ->
    #state{table = Table, stats = Stats} = State,
    FullKey = {Namespace, Key},
    ets:delete(Table, FullKey),
    NewStats = Stats#{
        deletes := maps:get(deletes, Stats) + 1
    },
    {reply, ok, State#state{stats = NewStats}};

handle_call({exists, Namespace, Key}, _From, State) ->
    #state{table = Table} = State,
    FullKey = {Namespace, Key},
    Result = ets:member(Table, FullKey),
    {reply, Result, State};

handle_call({list_keys, Namespace, Prefix}, _From, State) ->
    #state{table = Table} = State,

    %% Scan all keys in the namespace matching prefix
    Keys = ets:foldl(
        fun({{Ns, Key}, _Value}, Acc) when Ns =:= Namespace ->
            PrefixSize = byte_size(Prefix),
            case Key of
                <<Prefix:PrefixSize/binary, _/binary>> ->
                    [Key | Acc];
                _ when Prefix =:= <<>> ->
                    [Key | Acc];
                _ ->
                    Acc
            end;
           (_, Acc) ->
            Acc
        end,
        [],
        Table
    ),
    {reply, {ok, lists:sort(Keys)}, State};

handle_call(info, _From, State) ->
    #state{device_path = DevicePath, table = Table, stats = Stats} = State,
    Info = #{
        device_path => DevicePath,
        mock => true,
        io_uring => false,
        max_key_size => ?MAX_KEY_SIZE,
        max_value_size => ?MAX_VALUE_SIZE,
        key_count => ets:info(Table, size),
        stats => Stats
    },
    {reply, {ok, Info}, State};

handle_call(close, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{table = Table}) ->
    ets:delete(Table),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

validate_kv(Key, Value) ->
    KeySize = byte_size(Key),
    ValueSize = byte_size(Value),

    if
        KeySize < 1 ->
            {error, key_too_short};
        KeySize > ?MAX_KEY_SIZE ->
            {error, key_too_long};
        ValueSize > ?MAX_VALUE_SIZE ->
            {error, value_too_large};
        true ->
            ok
    end.
