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

%% gen_quic - High-Level QUIC Interface for Erlang Developers
%%
%% This module provides a gen_tcp-style API for QUIC connections.
%% Developers familiar with gen_tcp will find the patterns identical,
%% with the addition of stream multiplexing.
%%
%% == Quick Start ==
%%
%% Server:
%%   {ok, L} = gen_quic:listen(4433, [binary, {certfile, "cert.pem"},
%%                                     {keyfile, "key.pem"},
%%                                     {alpn, [<<"h3">>]}]),
%%   {ok, Conn} = gen_quic:accept(L),
%%   {ok, Stream} = gen_quic:accept_stream(Conn),
%%   {ok, Data} = gen_quic:recv(Stream, 0),
%%   ok = gen_quic:send(Stream, Data).
%%
%% Client:
%%   {ok, Conn} = gen_quic:connect("localhost", 4433,
%%                                  [binary, {alpn, [<<"h3">>]},
%%                                   {verify, verify_none}]),
%%   {ok, Stream} = gen_quic:open_stream(Conn),
%%   ok = gen_quic:send(Stream, <<"Hello">>),
%%   {ok, Reply} = gen_quic:recv(Stream, 0).
%%
%% == Active Mode ==
%%
%% Messages delivered to the controlling process:
%%   {quic, StreamRef, Data}                     - Stream data
%%   {quic_stream_opened, Connection, StreamRef} - New stream from peer
%%   {quic_stream_closed, StreamRef}             - Stream FIN received
%%   {quic_closed, Connection}                   - Connection closed
%%   {quic_error, Ref, Reason}                   - Error
%%   {quic_datagram, Connection, Data}           - Unreliable datagram

-module(gen_quic).

-export([
    %% Connection management
    connect/3, connect/4,
    listen/2,
    accept/1, accept/2,
    close/1, close/2,
    controlling_process/2,
    connection_info/1,
    %% Stream management
    open_stream/1, open_stream/2,
    accept_stream/1, accept_stream/2,
    send/2,
    recv/2, recv/3,
    close_stream/1, close_stream/2,
    %% Unreliable datagrams (RFC 9221)
    send_datagram/2,
    recv_datagram/1, recv_datagram/2
]).

-define(DEFAULT_TIMEOUT, 30000).

%% ===================================================================
%% Connection Management
%% ===================================================================

%% @doc Connect to a QUIC server.
-spec connect(inet:hostname() | inet:ip_address(),
              inet:port_number(), list()) ->
    {ok, pid()} | {error, term()}.
connect(Host, Port, Opts) ->
    connect(Host, Port, Opts, ?DEFAULT_TIMEOUT).

%% @doc Connect to a QUIC server with a timeout.
-spec connect(inet:hostname() | inet:ip_address(),
              inet:port_number(), list(), timeout()) ->
    {ok, pid()} | {error, term()}.
connect(Host, Port, Opts, Timeout) ->
    ensure_started(),
    Args = #{role => client, owner => self(), options => Opts},
    case quic_connection_sup:start_connection(Args) of
        {ok, ConnPid} ->
            case quic_connection:connect(ConnPid, Host, Port, Timeout) of
                {ok, ConnPid} ->
                    {ok, ConnPid};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Create a QUIC listener on a port.
-spec listen(inet:port_number(), list()) ->
    {ok, pid()} | {error, term()}.
listen(Port, Opts) ->
    ensure_started(),
    quic_listener_sup:start_listener(Port, Opts).

%% @doc Accept an incoming QUIC connection.
-spec accept(pid()) -> {ok, pid()} | {error, term()}.
accept(Listener) ->
    accept(Listener, infinity).

%% @doc Accept an incoming QUIC connection with timeout.
-spec accept(pid(), timeout()) -> {ok, pid()} | {error, term()}.
accept(Listener, Timeout) ->
    quic_listener:accept(Listener, Timeout).

%% @doc Close a QUIC connection or listener.
-spec close(pid()) -> ok.
close(Ref) ->
    close(Ref, 0).

%% @doc Close with an error code.
-spec close(pid(), non_neg_integer()) -> ok.
close(Ref, ErrorCode) ->
    try
        %% Try as connection first, then as listener
        case quic_connection:close(Ref, ErrorCode) of
            ok -> ok;
            _ -> quic_listener:close(Ref)
        end
    catch
        _:_ ->
            try quic_listener:close(Ref) catch _:_ -> ok end
    end.

%% @doc Change the controlling process of a connection.
-spec controlling_process(pid(), pid()) -> ok | {error, term()}.
controlling_process(Connection, NewOwner) ->
    quic_connection:controlling_process(Connection, NewOwner).

%% @doc Get connection information.
-spec connection_info(pid()) -> {ok, map()} | {error, term()}.
connection_info(Connection) ->
    quic_connection:connection_info(Connection).

%% ===================================================================
%% Stream Management
%% ===================================================================

%% @doc Open a new bidirectional stream.
-spec open_stream(pid()) -> {ok, {quic_stream, pid(), non_neg_integer()}} | {error, term()}.
open_stream(Connection) ->
    open_stream(Connection, [bidirectional]).

%% @doc Open a new stream with options.
%% Options: bidirectional | unidirectional
-spec open_stream(pid(), list()) ->
    {ok, {quic_stream, pid(), non_neg_integer()}} | {error, term()}.
open_stream(Connection, Opts) ->
    quic_connection:open_stream(Connection, Opts).

%% @doc Accept a peer-initiated stream.
-spec accept_stream(pid()) ->
    {ok, {quic_stream, pid(), non_neg_integer()}} | {error, term()}.
accept_stream(Connection) ->
    accept_stream(Connection, ?DEFAULT_TIMEOUT).

%% @doc Accept a peer-initiated stream with timeout.
-spec accept_stream(pid(), timeout()) ->
    {ok, {quic_stream, pid(), non_neg_integer()}} | {error, term()}.
accept_stream(Connection, Timeout) ->
    quic_connection:accept_stream(Connection, Timeout).

%% @doc Send data on a stream.
%% StreamRef is {quic_stream, ConnPid, StreamId}.
-spec send({quic_stream, pid(), non_neg_integer()}, iodata()) ->
    ok | {error, term()}.
send({quic_stream, ConnPid, StreamId}, Data) ->
    quic_connection:send(ConnPid, StreamId, iolist_to_binary(Data)).

%% @doc Receive data from a stream (passive mode).
%% Length=0 means return any available data.
-spec recv({quic_stream, pid(), non_neg_integer()}, non_neg_integer()) ->
    {ok, binary()} | {error, term()}.
recv(StreamRef, Length) ->
    recv(StreamRef, Length, ?DEFAULT_TIMEOUT).

%% @doc Receive data from a stream with timeout.
-spec recv({quic_stream, pid(), non_neg_integer()}, non_neg_integer(), timeout()) ->
    {ok, binary()} | {error, term()}.
recv({quic_stream, ConnPid, StreamId}, Length, Timeout) ->
    quic_connection:recv(ConnPid, StreamId, Length, Timeout).

%% @doc Close a stream.
-spec close_stream({quic_stream, pid(), non_neg_integer()}) -> ok.
close_stream(StreamRef) ->
    close_stream(StreamRef, 0).

%% @doc Close a stream with error code.
-spec close_stream({quic_stream, pid(), non_neg_integer()}, non_neg_integer()) -> ok.
close_stream({quic_stream, ConnPid, StreamId}, _ErrorCode) ->
    quic_connection:close_stream(ConnPid, StreamId).

%% ===================================================================
%% Unreliable Datagrams (RFC 9221)
%% ===================================================================

%% @doc Send an unreliable datagram on a connection.
-spec send_datagram(pid(), iodata()) -> ok | {error, term()}.
send_datagram(Connection, Data) ->
    quic_connection:send_datagram(Connection, iolist_to_binary(Data)).

%% @doc Receive an unreliable datagram.
-spec recv_datagram(pid()) -> {ok, binary()} | {error, term()}.
recv_datagram(Connection) ->
    recv_datagram(Connection, ?DEFAULT_TIMEOUT).

%% @doc Receive an unreliable datagram with timeout.
-spec recv_datagram(pid(), timeout()) -> {ok, binary()} | {error, term()}.
recv_datagram(Connection, Timeout) ->
    quic_connection:recv_datagram(Connection, Timeout).

%% ===================================================================
%% Internal
%% ===================================================================

ensure_started() ->
    case application:ensure_all_started(quic) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.
