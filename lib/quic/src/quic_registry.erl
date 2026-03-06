%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
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
%% %CopyrightEnd%
%%

-module(quic_registry).

-export([init/0, claim/2, release/1]).

-define(TABLE, quic_connections).

init() ->
    ets:new(?TABLE, [set, public, named_table,
                     {write_concurrency, true},
                     {read_concurrency, true}]).

claim(PeerAddr, ConnPid) ->
    ets:insert_new(?TABLE, {peer_key(PeerAddr), ConnPid}).

release(ConnPid) ->
    ets:match_delete(?TABLE, {'_', ConnPid}).

peer_key(#{addr := Addr, port := Port}) -> {Addr, Port};
peer_key(Other) -> Other.
