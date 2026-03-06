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

%% QUIC Listener
%%
%% Binds an unconnected UDP socket and watches for new Initial packets.
%% For each new peer, creates a connected UDP socket on the same port
%% and hands it to a fresh connection process. The kernel routes all
%% subsequent packets from that peer directly to the connected socket,
%% so the listener only ever sees traffic from unknown peers.

-module(quic_listener).

-behaviour(gen_statem).

-include("quic.hrl").

%% API
-export([
    start_link/2,
    accept/2,
    close/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    listening/3,
    terminate/3
]).

-record(listener_data, {
    socket          :: term(),
    port            :: inet:port_number(),
    options         :: list(),
    acceptors = []  :: [{gen_statem:from(), reference()}],
    pending = []    :: [pid()]
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link(inet:port_number(), list()) -> {ok, pid()} | {error, term()}.
start_link(Port, Opts) ->
    gen_statem:start_link(?MODULE, {Port, Opts}, []).

-spec accept(pid(), timeout()) -> {ok, pid()} | {error, term()}.
accept(Listener, Timeout) ->
    gen_statem:call(Listener, accept, Timeout).

-spec close(pid()) -> ok.
close(Listener) ->
    gen_statem:stop(Listener).

%% ===================================================================
%% gen_statem Callbacks
%% ===================================================================

callback_mode() -> state_functions.

init({Port, Opts}) ->
    case socket:open(inet, dgram, udp) of
        {ok, Socket} ->
            ok = socket:setopt(Socket, {socket, reuseaddr}, true),
            ok = socket:setopt(Socket, {socket, reuseport}, true),
            case socket:bind(Socket, #{family => inet, addr => any, port => Port}) of
                ok ->
                    socket:recvfrom(Socket, 0, [], nowait),
                    {ok, listening, #listener_data{
                        socket = Socket,
                        port = Port,
                        options = Opts
                    }};
                {error, Reason} ->
                    socket:close(Socket),
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

%% ===================================================================
%% State: listening
%% ===================================================================

listening({call, From}, accept, Data) ->
    case Data#listener_data.pending of
        [ConnPid | Rest] ->
            {keep_state, Data#listener_data{pending = Rest},
             [{reply, From, {ok, ConnPid}}]};
        [] ->
            Acceptors = Data#listener_data.acceptors ++ [{From, undefined}],
            {keep_state, Data#listener_data{acceptors = Acceptors}}
    end;

listening(info, {'$socket', Socket, select, _Ref},
          #listener_data{socket = Socket} = Data) ->
    drain_socket(Socket, Data);

listening(info, {'DOWN', _MonRef, process, Pid, _Reason}, Data) ->
    quic_registry:release(Pid),
    {keep_state, Data};

listening(info, Msg, _Data) ->
    io:format("[listener] unexpected info: ~p~n", [Msg]),
    keep_state_and_data.

drain_socket(Socket, Data) ->
    case socket:recvfrom(Socket, 0, [], nowait) of
        {ok, {Source, PacketData}} ->
            Data2 = handle_incoming_packet(PacketData, Source, Data),
            drain_socket(Socket, Data2);
        {select, _} ->
            {keep_state, Data};
        {error, Reason} ->
            io:format("[listener] recv error: ~p~n", [Reason]),
            {keep_state, Data}
    end.

terminate(_Reason, _State, #listener_data{socket = Socket}) ->
    socket:close(Socket),
    ok.

%% ===================================================================
%% Internal
%% ===================================================================

handle_incoming_packet(<<1:1, _:7, _/binary>> = PacketData, Source, Data) ->
    <<FB:8, _/binary>> = PacketData,
    Type = (FB band 16#30) bsr 4,
    case Type of
        ?INITIAL_PACKET ->
            create_new_connection(PacketData, Source, Data);
        _ ->
            Data
    end;
handle_incoming_packet(_PacketData, _Source, Data) ->
    Data.

create_new_connection(PacketData, PeerAddr, Data) ->
    #listener_data{socket = ListenSocket, options = Opts} = Data,
    Args = #{role => server, owner => self(), options => Opts},
    case quic_connection_sup:start_connection(Args) of
        {ok, ConnPid} ->
            case quic_registry:claim(PeerAddr, ConnPid) of
                true ->
                    monitor(process, ConnPid),
                    {ok, LocalAddr} = socket:sockname(ListenSocket),
                    case quic_connection:accept_init(ConnPid, LocalAddr,
                                                      PeerAddr, PacketData) of
                        {ok, _SCID} ->
                            ok;
                        {error, Reason} ->
                            io:format("[listener] accept_init failed: ~p~n", [Reason])
                    end,
                    case Data#listener_data.acceptors of
                        [{From, _} | RestAcceptors] ->
                            gen_statem:reply(From, {ok, ConnPid}),
                            Data#listener_data{acceptors = RestAcceptors};
                        [] ->
                            Data#listener_data{
                                pending = Data#listener_data.pending ++ [ConnPid]
                            }
                    end;
                false ->
                    Data
            end;
        {error, Reason} ->
            io:format("[listener] start_connection failed: ~p~n", [Reason]),
            Data
    end.
