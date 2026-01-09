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

%% @doc Mnesia backend for NVMe Key-Value SSDs.
%%
%% This module implements the mnesia_backend_type behavior to provide
%% storage on NVMe SSDs supporting the KV command set (NVMe 2.0+).
%%
%% == Usage ==
%% ```
%% %% Register the backend
%% mnesia:add_backend_type(nvme_kv_copies, mnesia_nvme_backend).
%%
%% %% Create a table using the backend
%% mnesia:create_table(my_table, [
%%     {attributes, [id, data]},
%%     {nvme_kv_copies, [node()]}
%% ]).
%% '''
%%
%% == Key Format ==
%% Keys are stored as: `<<TableNameHash:4/binary, ErlangTermKey/binary>>'
%% This allows efficient table-scoped operations on the KV device.
%%
%% == Value Format ==
%% Values are stored as: `erlang:term_to_binary(Record)'
%%
-module(mnesia_nvme_backend).

%% Mnesia backend_type callbacks (all 39 are mandatory)
-export([
    %% Initialization
    init_backend/0,
    add_aliases/1,
    remove_aliases/1,
    check_definition/4,
    semantics/2,

    %% Table lifecycle
    create_table/3,
    load_table/4,
    delete_table/2,
    close_table/2,
    sync_close_table/2,

    %% File suffixes
    real_suffixes/0,
    tmp_suffixes/0,

    %% Data operations
    insert/3,
    lookup/3,
    delete/3,
    match_delete/3,
    first/2,
    last/2,
    next/3,
    prev/3,
    slot/3,
    update_counter/4,
    select/1,
    select/3,
    select/4,
    fixtable/3,

    %% Record validation
    validate_key/6,
    validate_record/6,

    %% Index management
    index_is_consistent/3,
    is_index_consistent/2,
    repair_continuation/2,

    %% Replication support
    sender_init/4,
    receiver_first_message/4,
    receive_data/5,
    receive_done/4,

    %% Info
    info/3
]).

-record(state, {
    handle :: term(),
    device_path :: string(),
    namespace :: non_neg_integer(),
    tables :: map()  % #{atom() => #table_info{}}
}).

-record(table_info, {
    name :: atom(),
    type :: set | bag | ordered_set,
    key_pos :: non_neg_integer(),
    attributes :: [atom()],
    hash :: binary()  % 4-byte hash of table name for key prefix
}).

-record(continuation, {
    table :: atom(),
    match_spec :: term(),
    keys :: [binary()],
    position :: non_neg_integer()
}).

%% Persistent term key for backend state
-define(STATE_KEY, {?MODULE, state}).

%% NVMe namespace (typically 1)
-define(DEFAULT_NSID, 1).

%%====================================================================
%% Semantics
%%====================================================================

%% @doc Declare backend semantics.
%% - storage: disc_only_copies (data persists, not RAM-cached by us)
%% - types: set and bag (ordered_set requires sorted iteration which KV doesn't guarantee)
%% - index_types: bag indexes
semantics(nvme_kv_copies, storage) -> disc_only_copies;
semantics(nvme_kv_copies, types) -> [set, bag];
semantics(nvme_kv_copies, index_types) -> [bag];
semantics(_, _) -> undefined.

%%====================================================================
%% Initialization
%%====================================================================

%% @doc Initialize the backend. Called once when first registered.
init_backend() ->
    case persistent_term:get(?STATE_KEY, undefined) of
        undefined ->
            DevicePath = application:get_env(mnesia_nvme, device_path, "/dev/ng0n1"),
            State = #state{
                device_path = DevicePath,
                namespace = ?DEFAULT_NSID,
                tables = #{}
            },
            persistent_term:put(?STATE_KEY, State),
            ok;
        _ ->
            ok
    end.

%% @doc Called when aliases are added to this backend.
add_aliases(_Aliases) ->
    ensure_initialized(),
    ok.

%% @doc Called when aliases are removed from this backend.
remove_aliases(_Aliases) ->
    ok.

%%====================================================================
%% Table Lifecycle
%%====================================================================

%% @doc Validate table definition before creation.
check_definition(_Alias, _Tab, _Nodes, _Props) ->
    ok.

%% @doc Create a new table.
create_table(_Alias, Tab, Props) ->
    ensure_initialized(),
    Type = proplists:get_value(type, Props, set),
    Attributes = proplists:get_value(attributes, Props, [key, val]),
    KeyPos = proplists:get_value(keypos, Props, 1),

    %% Create a 4-byte hash of table name for key prefix
    TabBin = atom_to_binary(Tab, utf8),
    <<Hash:32, _/binary>> = crypto:hash(md5, TabBin),
    HashBin = <<Hash:32>>,

    TableInfo = #table_info{
        name = Tab,
        type = Type,
        key_pos = KeyPos,
        attributes = Attributes,
        hash = HashBin
    },

    State = get_state(),
    NewTables = maps:put(Tab, TableInfo, State#state.tables),
    put_state(State#state{tables = NewTables}),
    ok.

%% @doc Load an existing table.
load_table(_Alias, Tab, _LoadReason, CsList) ->
    ensure_initialized(),
    %% Extract table properties from CsList
    Type = proplists:get_value(type, CsList, set),
    Attributes = proplists:get_value(attributes, CsList, [key, val]),
    KeyPos = proplists:get_value(keypos, CsList, 1),

    TabBin = atom_to_binary(Tab, utf8),
    <<Hash:32, _/binary>> = crypto:hash(md5, TabBin),
    HashBin = <<Hash:32>>,

    TableInfo = #table_info{
        name = Tab,
        type = Type,
        key_pos = KeyPos,
        attributes = Attributes,
        hash = HashBin
    },

    State = get_state(),
    NewTables = maps:put(Tab, TableInfo, State#state.tables),
    put_state(State#state{tables = NewTables}),
    ok.

%% @doc Delete a table and all its data.
delete_table(_Alias, Tab) ->
    ensure_initialized(),
    State = get_state(),
    case maps:get(Tab, State#state.tables, undefined) of
        undefined ->
            ok;
        #table_info{hash = Hash} ->
            %% Delete all keys with this table's hash prefix
            Handle = ensure_device_open(State),
            delete_all_with_prefix(Handle, ?DEFAULT_NSID, Hash),
            NewTables = maps:remove(Tab, State#state.tables),
            put_state(State#state{tables = NewTables}),
            ok
    end.

%% @doc Close a table (non-sync).
close_table(_Alias, _Tab) ->
    ok.

%% @doc Close a table (sync).
sync_close_table(_Alias, _Tab) ->
    ok.

%%====================================================================
%% File Suffixes
%%====================================================================

%% @doc Real file suffixes used by this backend.
real_suffixes() -> [].

%% @doc Temporary file suffixes.
tmp_suffixes() -> [].

%%====================================================================
%% Data Operations
%%====================================================================

%% @doc Insert a record.
insert(_Alias, Tab, Obj) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash, type = Type, key_pos = KeyPos} = maps:get(Tab, State#state.tables),

    Key = element(KeyPos + 1, Obj),  % +1 because element is 1-indexed, keypos is 0-indexed for record name
    KvKey = make_kv_key(Hash, Key),

    case Type of
        bag ->
            %% For bags, we need to append to existing values
            ExistingValues = case mnesia_nvme_device:retrieve(Handle, ?DEFAULT_NSID, KvKey) of
                {ok, Bin} -> binary_to_term(Bin);
                {error, not_found} -> []
            end,
            NewValues = [Obj | lists:delete(Obj, ExistingValues)],
            KvValue = term_to_binary(NewValues);
        set ->
            KvValue = term_to_binary([Obj])
    end,

    case mnesia_nvme_device:store(Handle, ?DEFAULT_NSID, KvKey, KvValue) of
        ok -> ok;
        {error, Reason} -> erlang:error({nvme_store_error, Reason})
    end.

%% @doc Lookup records by key.
lookup(_Alias, Tab, Key) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    KvKey = make_kv_key(Hash, Key),
    case mnesia_nvme_device:retrieve(Handle, ?DEFAULT_NSID, KvKey) of
        {ok, Bin} -> binary_to_term(Bin);
        {error, not_found} -> [];
        {error, Reason} -> erlang:error({nvme_retrieve_error, Reason})
    end.

%% @doc Delete records by key.
delete(_Alias, Tab, Key) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    KvKey = make_kv_key(Hash, Key),
    case mnesia_nvme_device:delete(Handle, ?DEFAULT_NSID, KvKey) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, Reason} -> erlang:error({nvme_delete_error, Reason})
    end.

%% @doc Delete records matching a pattern.
match_delete(_Alias, Tab, Pattern) ->
    %% This requires scanning all keys - expensive but necessary
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, Keys} ->
            lists:foreach(fun(KvKey) ->
                case mnesia_nvme_device:retrieve(Handle, ?DEFAULT_NSID, KvKey) of
                    {ok, Bin} ->
                        Records = binary_to_term(Bin),
                        Remaining = [R || R <- Records, not matches_pattern(R, Pattern)],
                        case Remaining of
                            [] ->
                                mnesia_nvme_device:delete(Handle, ?DEFAULT_NSID, KvKey);
                            _ ->
                                mnesia_nvme_device:store(Handle, ?DEFAULT_NSID, KvKey, term_to_binary(Remaining))
                        end;
                    _ ->
                        ok
                end
            end, Keys),
            ok;
        {error, Reason} ->
            erlang:error({nvme_list_error, Reason})
    end.

%% @doc Get the first key.
first(_Alias, Tab) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, []} -> '$end_of_table';
        {ok, [KvKey | _]} -> extract_key(Hash, KvKey);
        {error, _} -> '$end_of_table'
    end.

%% @doc Get the last key.
last(_Alias, Tab) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, []} -> '$end_of_table';
        {ok, Keys} -> extract_key(Hash, lists:last(Keys));
        {error, _} -> '$end_of_table'
    end.

%% @doc Get the next key after Key.
next(_Alias, Tab, Key) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    KvKey = make_kv_key(Hash, Key),
    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, Keys} ->
            find_next_key(Keys, KvKey, Hash);
        {error, _} ->
            '$end_of_table'
    end.

%% @doc Get the previous key before Key.
prev(_Alias, Tab, Key) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    KvKey = make_kv_key(Hash, Key),
    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, Keys} ->
            find_prev_key(Keys, KvKey, Hash);
        {error, _} ->
            '$end_of_table'
    end.

%% @doc Get records at slot position (for dirty iteration).
slot(_Alias, Tab, Pos) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, Keys} when Pos < length(Keys) ->
            KvKey = lists:nth(Pos + 1, Keys),
            case mnesia_nvme_device:retrieve(Handle, ?DEFAULT_NSID, KvKey) of
                {ok, Bin} -> binary_to_term(Bin);
                _ -> '$end_of_table'
            end;
        _ ->
            '$end_of_table'
    end.

%% @doc Update a counter.
update_counter(_Alias, Tab, Key, Incr) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    KvKey = make_kv_key(Hash, Key),
    OldVal = case mnesia_nvme_device:retrieve(Handle, ?DEFAULT_NSID, KvKey) of
        {ok, Bin} ->
            case binary_to_term(Bin) of
                [{_, _, V}] when is_integer(V) -> V;
                _ -> 0
            end;
        _ -> 0
    end,
    NewVal = OldVal + Incr,
    %% Store as a simple counter record {Tab, Key, Value}
    Record = {Tab, Key, NewVal},
    mnesia_nvme_device:store(Handle, ?DEFAULT_NSID, KvKey, term_to_binary([Record])),
    NewVal.

%% @doc Select with continuation.
select(#continuation{table = Tab, match_spec = Ms, keys = Keys, position = Pos}) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    CompiledMs = ets:match_spec_compile(Ms),
    select_loop(Handle, Hash, Keys, Pos, CompiledMs, [], 100).

%% @doc Select all matching records.
select(_Alias, Tab, Ms) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, Keys} ->
            CompiledMs = ets:match_spec_compile(Ms),
            {Results, _} = select_loop(Handle, Hash, Keys, 0, CompiledMs, [], infinity),
            Results;
        {error, _} ->
            []
    end.

%% @doc Select with limit.
select(_Alias, Tab, Ms, Limit) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, Keys} ->
            CompiledMs = ets:match_spec_compile(Ms),
            select_loop(Handle, Hash, Keys, 0, CompiledMs, [], Limit);
        {error, _} ->
            '$end_of_table'
    end.

%% @doc Fix/unfix table for consistent iteration.
fixtable(_Alias, _Tab, _Bool) ->
    ok.

%%====================================================================
%% Record Validation
%%====================================================================

validate_key(_Alias, _Tab, RecName, Arity, Type, _Key) ->
    {RecName, Arity, Type}.

validate_record(_Alias, _Tab, RecName, Arity, Type, _Obj) ->
    {RecName, Arity, Type}.

%%====================================================================
%% Index Management
%%====================================================================

index_is_consistent(_Alias, _Ix, _Bool) ->
    ok.

is_index_consistent(_Alias, _Ix) ->
    true.

repair_continuation(Cont, _Ms) ->
    Cont.

%%====================================================================
%% Replication Support
%%====================================================================

%% @doc Initialize sender for table copy.
sender_init(_Alias, Tab, _LoadReason, _Pid) ->
    State = get_state(),
    Handle = ensure_device_open(State),
    #table_info{hash = Hash} = maps:get(Tab, State#state.tables),

    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
        {ok, Keys} ->
            %% Return all data as chunks
            AllData = lists:foldl(fun(KvKey, Acc) ->
                case mnesia_nvme_device:retrieve(Handle, ?DEFAULT_NSID, KvKey) of
                    {ok, Bin} -> binary_to_term(Bin) ++ Acc;
                    _ -> Acc
                end
            end, [], Keys),
            ChunkFun = fun
                F([]) -> {[], F};
                F(Data) ->
                    {Chunk, Rest} = safe_split(100, Data),
                    {Chunk, fun() -> F(Rest) end}
            end,
            {ChunkFun(AllData), ChunkFun};
        {error, _} ->
            {{[], fun() -> {[], fun() -> {[], undefined} end} end}, undefined}
    end.

%% @doc Handle first message from sender.
receiver_first_message(_Sender, {first, Size}, _Alias, _Tab) ->
    {Size, []}.

%% @doc Receive data chunk.
receive_data(Data, _Alias, Tab, _Sender, State) ->
    %% Insert received records
    lists:foreach(fun(Obj) ->
        insert(nvme_kv_copies, Tab, Obj)
    end, Data),
    {more, State}.

%% @doc Receive done.
receive_done(_Alias, _Tab, _Sender, _State) ->
    ok.

%%====================================================================
%% Info
%%====================================================================

%% @doc Get table info.
info(_Alias, Tab, Item) ->
    State = get_state(),
    case maps:get(Tab, State#state.tables, undefined) of
        undefined ->
            undefined;
        #table_info{type = Type, hash = Hash} ->
            Handle = ensure_device_open(State),
            case Item of
                type -> Type;
                size ->
                    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
                        {ok, Keys} -> length(Keys);
                        _ -> 0
                    end;
                memory ->
                    %% Rough estimate
                    case mnesia_nvme_device:list_keys(Handle, ?DEFAULT_NSID, Hash) of
                        {ok, Keys} -> length(Keys) * 1024;
                        _ -> 0
                    end;
                _ ->
                    undefined
            end
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

ensure_initialized() ->
    case persistent_term:get(?STATE_KEY, undefined) of
        undefined -> init_backend();
        _ -> ok
    end.

get_state() ->
    persistent_term:get(?STATE_KEY).

put_state(State) ->
    persistent_term:put(?STATE_KEY, State).

ensure_device_open(#state{handle = undefined, device_path = Path} = State) ->
    case mnesia_nvme_device:open(Path) of
        {ok, Handle} ->
            put_state(State#state{handle = Handle}),
            Handle;
        {error, Reason} ->
            erlang:error({nvme_open_error, Path, Reason})
    end;
ensure_device_open(#state{handle = Handle}) ->
    Handle.

%% Create a KV key from table hash and Erlang term key
make_kv_key(Hash, Key) ->
    KeyBin = term_to_binary(Key),
    <<Hash/binary, KeyBin/binary>>.

%% Extract Erlang term key from KV key
extract_key(Hash, KvKey) ->
    HashSize = byte_size(Hash),
    <<_:HashSize/binary, KeyBin/binary>> = KvKey,
    binary_to_term(KeyBin).

find_next_key([], _Target, _Hash) ->
    '$end_of_table';
find_next_key([K | Rest], Target, Hash) ->
    case K > Target of
        true -> extract_key(Hash, K);
        false -> find_next_key(Rest, Target, Hash)
    end.

find_prev_key(Keys, Target, Hash) ->
    find_prev_key(Keys, Target, Hash, undefined).

find_prev_key([], _Target, _Hash, undefined) ->
    '$end_of_table';
find_prev_key([], _Target, Hash, Prev) ->
    extract_key(Hash, Prev);
find_prev_key([K | _], Target, Hash, Prev) when K >= Target ->
    case Prev of
        undefined -> '$end_of_table';
        _ -> extract_key(Hash, Prev)
    end;
find_prev_key([K | Rest], Target, Hash, _Prev) ->
    find_prev_key(Rest, Target, Hash, K).

delete_all_with_prefix(Handle, Nsid, Prefix) ->
    case mnesia_nvme_device:list_keys(Handle, Nsid, Prefix) of
        {ok, Keys} ->
            lists:foreach(fun(K) ->
                mnesia_nvme_device:delete(Handle, Nsid, K)
            end, Keys);
        _ ->
            ok
    end.

matches_pattern(Record, Pattern) when is_tuple(Record), is_tuple(Pattern) ->
    match_tuple(Record, Pattern, 1, tuple_size(Pattern)).

match_tuple(_Record, _Pattern, N, Size) when N > Size ->
    true;
match_tuple(Record, Pattern, N, Size) ->
    case element(N, Pattern) of
        '_' ->
            match_tuple(Record, Pattern, N + 1, Size);
        Val when N =< tuple_size(Record) ->
            case element(N, Record) of
                Val -> match_tuple(Record, Pattern, N + 1, Size);
                _ -> false
            end;
        _ ->
            false
    end.

select_loop(_Handle, _Hash, [], _Pos, _Ms, Acc, _Limit) ->
    {lists:reverse(Acc), '$end_of_table'};
select_loop(_Handle, Hash, Keys, Pos, Ms, Acc, Limit) when length(Acc) >= Limit, Limit =/= infinity ->
    Cont = #continuation{table = undefined, match_spec = Ms, keys = Keys, position = Pos},
    {lists:reverse(Acc), Cont};
select_loop(Handle, Hash, [KvKey | Rest], Pos, Ms, Acc, Limit) ->
    NewAcc = case mnesia_nvme_device:retrieve(Handle, ?DEFAULT_NSID, KvKey) of
        {ok, Bin} ->
            Records = binary_to_term(Bin),
            Matches = ets:match_spec_run(Records, Ms),
            Matches ++ Acc;
        _ ->
            Acc
    end,
    select_loop(Handle, Hash, Rest, Pos + 1, Ms, NewAcc, Limit).

safe_split(N, List) when length(List) =< N ->
    {List, []};
safe_split(N, List) ->
    lists:split(N, List).
