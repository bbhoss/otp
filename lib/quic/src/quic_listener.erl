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

%% QUIC Listener (Server-side UDP packet demuxer)
%%
%% Binds a UDP socket and demultiplexes incoming packets to connection
%% processes based on the Destination Connection ID. New Initial packets
%% create new connections through the connection supervisor.

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
    %% Connection ID -> Connection Pid mapping
    connections = #{} :: #{binary() => pid()},
    %% Queue of processes waiting for new connections
    acceptors = []    :: [{gen_statem:from(), reference()}],
    %% Pending connections not yet accepted
    pending = []      :: [pid()],
    %% Monitor refs
    conn_monitors = #{} :: #{reference() => binary()}
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
            case socket:bind(Socket, #{family => inet, addr => any, port => Port}) of
                ok ->
                    %% Start receiving
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

listening(info, {'DOWN', MonRef, process, _Pid, _Reason}, Data) ->
    %% Connection process died - remove from routing table
    case maps:take(MonRef, Data#listener_data.conn_monitors) of
        {DCID, NewMonitors} ->
            NewConns = maps:remove(DCID, Data#listener_data.connections),
            {keep_state, Data#listener_data{
                connections = NewConns,
                conn_monitors = NewMonitors
            }};
        error ->
            {keep_state, Data}
    end;

listening(info, {register_scid, SCID, ConnPid}, Data) ->
    %% Connection process registering its SCID for routing
    NewConns = maps:put(SCID, ConnPid, Data#listener_data.connections),
    {keep_state, Data#listener_data{connections = NewConns}};

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

handle_incoming_packet(PacketData, Source, Data) ->
    case PacketData of
        <<1:1, _:7, _/binary>> ->
            %% Long header - extract DCID
            case extract_dcid(PacketData) of
                {ok, DCID} ->
                    case maps:find(DCID, Data#listener_data.connections) of
                        {ok, ConnPid} ->
                            %% Route to existing connection
                            quic_connection:handle_packet(ConnPid, {PacketData, Source}),
                            Data;
                        error ->
                            %% Check if this is an Initial packet
                            <<_FB:8, _Version:32, _/binary>> = PacketData,
                            <<FB:8, _/binary>> = PacketData,
                            Type = (FB band 16#30) bsr 4,
                            case Type of
                                ?INITIAL_PACKET ->
                                    create_new_connection(PacketData, Source, DCID, Data);
                                _ ->
                                    Data
                            end
                    end;
                {error, _} ->
                    Data
            end;
        <<0:1, _:7, _/binary>> ->
            %% Short header - need to try known DCID lengths
            %% For simplicity, try 8-byte DCID (our default)
            case byte_size(PacketData) > 9 of
                true ->
                    <<_:1/binary, DCID:8/binary, _/binary>> = PacketData,
                    case maps:find(DCID, Data#listener_data.connections) of
                        {ok, ConnPid} ->
                            quic_connection:handle_packet(ConnPid, {PacketData, Source}),
                            Data;
                        error ->
                            Data
                    end;
                false ->
                    Data
            end;
        _ ->
            Data
    end.

create_new_connection(PacketData, Source, DCID, Data) ->
    %% Start a new connection process
    Opts = Data#listener_data.options,
    Args = #{role => server, owner => self(), options => Opts},
    case quic_connection_sup:start_connection(Args) of
        {ok, ConnPid} ->
            %% Register the connection
            MonRef = erlang:monitor(process, ConnPid),
            NewConns = maps:put(DCID, ConnPid, Data#listener_data.connections),
            NewMonitors = maps:put(MonRef, DCID, Data#listener_data.conn_monitors),

            %% Also register the server's SCID for future routing
            %% The connection will tell us its SCID later

            %% Initialize the connection with the Initial packet
            case quic_connection:accept_init(ConnPid, Data#listener_data.socket,
                                              Source, PacketData) of
                {ok, SCID} ->
                    %% Register SCID for routing future packets
                    NewConns2 = maps:put(SCID, ConnPid, NewConns),
                    ok;
                {error, _} ->
                    NewConns2 = NewConns,
                    ok
            end,

            %% Deliver to acceptor or queue
            case Data#listener_data.acceptors of
                [{From, _} | RestAcceptors] ->
                    gen_statem:reply(From, {ok, ConnPid}),
                    Data#listener_data{
                        connections = NewConns2,
                        conn_monitors = NewMonitors,
                        acceptors = RestAcceptors
                    };
                [] ->
                    Data#listener_data{
                        connections = NewConns2,
                        conn_monitors = NewMonitors,
                        pending = Data#listener_data.pending ++ [ConnPid]
                    }
            end;
        {error, _Reason} ->
            Data
    end.

extract_dcid(<<_FB:8, _Version:32, DCIDLen:8, DCID:DCIDLen/binary, _/binary>>) ->
    {ok, DCID};
extract_dcid(_) ->
    {error, invalid_packet}.
