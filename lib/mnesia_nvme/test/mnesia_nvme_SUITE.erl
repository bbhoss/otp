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

%% @doc Common Test suite for mnesia_nvme backend.
-module(mnesia_nvme_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    %% Mock device tests
    mock_open_close/1,
    mock_store_retrieve/1,
    mock_delete/1,
    mock_exists/1,
    mock_list_keys/1,
    mock_prefix_filter/1,
    mock_large_value/1,

    %% Device abstraction tests
    device_auto_select/1,

    %% Mnesia backend tests
    backend_register/1,
    backend_create_table/1,
    backend_insert_lookup/1,
    backend_delete/1,
    backend_select/1,
    backend_iteration/1
]).

all() ->
    [{group, mock_tests},
     {group, device_tests},
     {group, backend_tests}].

groups() ->
    [{mock_tests, [sequence],
      [mock_open_close,
       mock_store_retrieve,
       mock_delete,
       mock_exists,
       mock_list_keys,
       mock_prefix_filter,
       mock_large_value]},
     {device_tests, [sequence],
      [device_auto_select]},
     {backend_tests, [sequence],
      [backend_register,
       backend_create_table,
       backend_insert_lookup,
       backend_delete,
       backend_select,
       backend_iteration]}].

init_per_suite(Config) ->
    %% Force mock backend for testing
    application:set_env(mnesia_nvme, backend, mock),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(backend_tests, Config) ->
    %% Start mnesia for backend tests
    mnesia:stop(),
    ok = mnesia:delete_schema([node()]),
    ok = mnesia:create_schema([node()]),
    ok = mnesia:start(),
    Config;
init_per_group(_Group, Config) ->
    Config.

end_per_group(backend_tests, _Config) ->
    mnesia:stop(),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Mock Device Tests
%%====================================================================

mock_open_close(_Config) ->
    {ok, Handle} = mnesia_nvme_mock:open("/dev/mock"),
    ?assertMatch({ok, #{mock := true}}, mnesia_nvme_mock:info(Handle)),
    ok = mnesia_nvme_mock:close(Handle).

mock_store_retrieve(_Config) ->
    {ok, H} = mnesia_nvme_mock:open("/dev/mock"),

    Key = <<"test_key">>,
    Value = <<"test_value_12345">>,

    ok = mnesia_nvme_mock:store(H, 1, Key, Value),
    ?assertEqual({ok, Value}, mnesia_nvme_mock:retrieve(H, 1, Key)),

    %% Non-existent key
    ?assertEqual({error, not_found}, mnesia_nvme_mock:retrieve(H, 1, <<"no_such_key">>)),

    ok = mnesia_nvme_mock:close(H).

mock_delete(_Config) ->
    {ok, H} = mnesia_nvme_mock:open("/dev/mock"),

    Key = <<"delete_me">>,
    Value = <<"some_value">>,

    ok = mnesia_nvme_mock:store(H, 1, Key, Value),
    ?assertEqual({ok, Value}, mnesia_nvme_mock:retrieve(H, 1, Key)),

    ok = mnesia_nvme_mock:delete(H, 1, Key),
    ?assertEqual({error, not_found}, mnesia_nvme_mock:retrieve(H, 1, Key)),

    ok = mnesia_nvme_mock:close(H).

mock_exists(_Config) ->
    {ok, H} = mnesia_nvme_mock:open("/dev/mock"),

    Key = <<"exists_test">>,
    Value = <<"value">>,

    ?assertEqual(false, mnesia_nvme_mock:exists(H, 1, Key)),

    ok = mnesia_nvme_mock:store(H, 1, Key, Value),
    ?assertEqual(true, mnesia_nvme_mock:exists(H, 1, Key)),

    ok = mnesia_nvme_mock:delete(H, 1, Key),
    ?assertEqual(false, mnesia_nvme_mock:exists(H, 1, Key)),

    ok = mnesia_nvme_mock:close(H).

mock_list_keys(_Config) ->
    {ok, H} = mnesia_nvme_mock:open("/dev/mock"),

    %% Insert several keys
    ok = mnesia_nvme_mock:store(H, 1, <<"key1">>, <<"v1">>),
    ok = mnesia_nvme_mock:store(H, 1, <<"key2">>, <<"v2">>),
    ok = mnesia_nvme_mock:store(H, 1, <<"key3">>, <<"v3">>),

    %% List all keys (empty prefix)
    {ok, Keys} = mnesia_nvme_mock:list_keys(H, 1, <<>>),
    ?assertEqual(3, length(Keys)),
    ?assert(lists:member(<<"key1">>, Keys)),
    ?assert(lists:member(<<"key2">>, Keys)),
    ?assert(lists:member(<<"key3">>, Keys)),

    ok = mnesia_nvme_mock:close(H).

mock_prefix_filter(_Config) ->
    {ok, H} = mnesia_nvme_mock:open("/dev/mock"),

    %% Insert keys with different prefixes
    ok = mnesia_nvme_mock:store(H, 1, <<"user:1">>, <<"alice">>),
    ok = mnesia_nvme_mock:store(H, 1, <<"user:2">>, <<"bob">>),
    ok = mnesia_nvme_mock:store(H, 1, <<"item:1">>, <<"apple">>),
    ok = mnesia_nvme_mock:store(H, 1, <<"item:2">>, <<"banana">>),

    %% Filter by prefix
    {ok, UserKeys} = mnesia_nvme_mock:list_keys(H, 1, <<"user:">>),
    ?assertEqual(2, length(UserKeys)),
    ?assert(lists:member(<<"user:1">>, UserKeys)),
    ?assert(lists:member(<<"user:2">>, UserKeys)),

    {ok, ItemKeys} = mnesia_nvme_mock:list_keys(H, 1, <<"item:">>),
    ?assertEqual(2, length(ItemKeys)),

    ok = mnesia_nvme_mock:close(H).

mock_large_value(_Config) ->
    {ok, H} = mnesia_nvme_mock:open("/dev/mock"),

    Key = <<"large_key">>,
    %% Create a 1MB value
    Value = binary:copy(<<"X">>, 1024 * 1024),

    ok = mnesia_nvme_mock:store(H, 1, Key, Value),
    {ok, Retrieved} = mnesia_nvme_mock:retrieve(H, 1, Key),
    ?assertEqual(Value, Retrieved),

    ok = mnesia_nvme_mock:close(H).

%%====================================================================
%% Device Abstraction Tests
%%====================================================================

device_auto_select(_Config) ->
    %% With mock backend configured, should select mock
    {ok, H} = mnesia_nvme_device:open("/dev/mock"),
    ?assertEqual(mock, mnesia_nvme_device:backend()),

    ok = mnesia_nvme_device:store(H, 1, <<"dev_key">>, <<"dev_value">>),
    ?assertEqual({ok, <<"dev_value">>}, mnesia_nvme_device:retrieve(H, 1, <<"dev_key">>)),

    ok = mnesia_nvme_device:close(H).

%%====================================================================
%% Mnesia Backend Tests
%%====================================================================

backend_register(_Config) ->
    %% Register the backend
    ok = mnesia:add_backend_type(nvme_kv_copies, mnesia_nvme_backend),

    %% Verify it's registered (check schema)
    ct:pal("Backend registered successfully").

backend_create_table(_Config) ->
    %% Create a table using the NVMe backend
    {atomic, ok} = mnesia:create_table(test_nvme_table, [
        {attributes, [id, name, data]},
        {type, set},
        {nvme_kv_copies, [node()]}
    ]),

    ct:pal("Table created successfully").

backend_insert_lookup(_Config) ->
    %% Insert some records
    F = fun() ->
        mnesia:write({test_nvme_table, 1, "Alice", <<"data1">>}),
        mnesia:write({test_nvme_table, 2, "Bob", <<"data2">>}),
        mnesia:write({test_nvme_table, 3, "Charlie", <<"data3">>})
    end,
    {atomic, ok} = mnesia:transaction(F),

    %% Lookup records
    G = fun() ->
        mnesia:read(test_nvme_table, 1)
    end,
    {atomic, [Record]} = mnesia:transaction(G),
    ?assertMatch({test_nvme_table, 1, "Alice", <<"data1">>}, Record),

    ct:pal("Insert/lookup successful").

backend_delete(_Config) ->
    %% Delete a record
    F = fun() ->
        mnesia:delete({test_nvme_table, 2})
    end,
    {atomic, ok} = mnesia:transaction(F),

    %% Verify it's gone
    G = fun() ->
        mnesia:read(test_nvme_table, 2)
    end,
    {atomic, []} = mnesia:transaction(G),

    ct:pal("Delete successful").

backend_select(_Config) ->
    %% Select all records
    F = fun() ->
        mnesia:select(test_nvme_table, [{'$1', [], ['$1']}])
    end,
    {atomic, Records} = mnesia:transaction(F),
    ?assertEqual(2, length(Records)),  % 1 and 3 remain after delete

    ct:pal("Select successful: ~p records", [length(Records)]).

backend_iteration(_Config) ->
    %% Test dirty iteration
    First = mnesia:dirty_first(test_nvme_table),
    ?assertNotEqual('$end_of_table', First),

    %% Iterate through all keys
    Keys = collect_keys(test_nvme_table, First, []),
    ?assertEqual(2, length(Keys)),

    ct:pal("Iteration successful: keys = ~p", [Keys]).

%%====================================================================
%% Helper Functions
%%====================================================================

collect_keys(_Tab, '$end_of_table', Acc) ->
    lists:reverse(Acc);
collect_keys(Tab, Key, Acc) ->
    Next = mnesia:dirty_next(Tab, Key),
    collect_keys(Tab, Next, [Key | Acc]).
