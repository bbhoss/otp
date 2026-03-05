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

%% quic_chat_server - Multi-room Chat Server over QUIC
%%
%% Demonstrates gen_quic active mode with QUIC stream multiplexing.
%% Each chat room is carried on its own QUIC bidirectional stream,
%% showcasing independent, non-head-of-line-blocking communication.
%%
%% Protocol (length-prefixed JSON, one stream per room):
%%
%%   Wire format:  <<Length:32/big, JSON:Length/binary>>
%%
%%   A client opens a NEW QUIC stream for each room it wants to join.
%%   The first message on a stream must be a join command:
%%
%%   Client -> Server (on new stream):
%%     {"cmd":"join",  "room":"lobby",  "nick":"alice"}
%%
%%   Then on that same stream:
%%     {"cmd":"msg",   "text":"hello everyone"}
%%
%%   Server -> Client (on the room's stream):
%%     {"ev":"joined",  "room":"lobby",  "members":["bob"]}
%%     {"ev":"msg",     "room":"lobby",  "nick":"bob",  "text":"hi"}
%%     {"ev":"enter",   "room":"lobby",  "nick":"alice"}
%%     {"ev":"left",    "room":"lobby",  "nick":"bob"}
%%     {"ev":"error",   "text":"not in a room"}
%%
%%   Closing the stream = leaving the room.
%%
%% Usage:
%%   {ok, Pid} = quic_chat_server:start(4433, "cert.pem", "key.pem").
%%   quic_chat_server:stop(Pid).

-module(quic_chat_server).

-export([start/3, stop/1]).

%% Internal exports for spawn_link
-export([acceptor_loop/1, connection_handler/2, room_proc/2]).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

start(Port, CertFile, KeyFile) ->
    RoomMgr = spawn_link(fun() -> room_manager(#{}) end),
    register(quic_chat_rooms, RoomMgr),
    {ok, L} = gen_quic:listen(Port, [
        binary,
        {active, true},
        {certfile, CertFile},
        {keyfile, KeyFile},
        {alpn, [<<"chat">>]}
    ]),
    io:format("[chat] Listening on port ~p~n", [Port]),
    Pid = spawn_link(fun() -> acceptor_loop(L) end),
    {ok, Pid}.

stop(Pid) ->
    exit(Pid, shutdown),
    case whereis(quic_chat_rooms) of
        undefined -> ok;
        RoomPid -> exit(RoomPid, shutdown)
    end,
    ok.

%%--------------------------------------------------------------------
%% Acceptor: loops accepting new QUIC connections
%%--------------------------------------------------------------------

acceptor_loop(Listener) ->
    case gen_quic:accept(Listener) of
        {ok, Conn} ->
            io:format("[chat] New connection: ~p~n", [Conn]),
            spawn(fun() -> connection_handler(Conn, undefined) end),
            acceptor_loop(Listener);
        {error, Reason} ->
            io:format("[chat] Accept error: ~p~n", [Reason])
    end.

%%--------------------------------------------------------------------
%% Connection handler: one per QUIC connection
%%
%% Manages MULTIPLE streams, each mapped to a room.
%% This is the key multiplexing demonstration: each room lives on
%% its own independent QUIC stream with zero head-of-line blocking.
%%--------------------------------------------------------------------

-record(client, {
    conn,
    nick = undefined,
    %% #{StreamRef => {RoomName, RoomPid, Buffer} | {pending, Buffer}}
    %% 'pending' means the stream opened but hasn't sent a join yet
    streams = #{}
}).

connection_handler(Conn, _Parent) ->
    gen_quic:controlling_process(Conn, self()),
    client_loop(#client{conn = Conn}).

client_loop(#client{conn = Conn} = St) ->
    receive
        %% A new stream was opened by the peer
        {quic_stream_opened, Conn, Stream} ->
            io:format("[chat] Stream opened: ~p~n", [Stream]),
            Streams = St#client.streams,
            client_loop(St#client{streams = Streams#{Stream => {pending, <<>>}}});

        %% Data arrived on a stream
        {quic, Stream, Data} ->
            case maps:get(Stream, St#client.streams, undefined) of
                undefined ->
                    %% Unknown stream, ignore
                    client_loop(St);
                {pending, Buf} ->
                    %% Stream not yet joined — buffer data and try to parse join
                    NewBuf = <<Buf/binary, Data/binary>>,
                    St2 = process_pending_stream(St, Stream, NewBuf),
                    client_loop(St2);
                {RoomName, RoomPid, Buf} ->
                    %% Stream is bound to a room — process commands
                    NewBuf = <<Buf/binary, Data/binary>>,
                    {NewBuf2, St2} = process_room_frames(St, Stream, RoomName, RoomPid, NewBuf),
                    Streams = St2#client.streams,
                    client_loop(St2#client{streams = Streams#{Stream => {RoomName, RoomPid, NewBuf2}}})
            end;

        %% Room broadcast: a message from another user
        {room_msg, RoomName, Msg} ->
            %% Find the stream for this room and send the event
            send_to_room_stream(St, RoomName, Msg),
            client_loop(St);

        %% Stream closed — leave that room
        {quic_stream_closed, Stream} ->
            St2 = handle_stream_close(St, Stream),
            client_loop(St2);

        %% Connection closed — leave all rooms
        {quic_closed, Conn} ->
            io:format("[chat] Connection closed~n"),
            leave_all_rooms(St);

        {quic_error, _Ref, Reason} ->
            io:format("[chat] Error: ~p~n", [Reason]),
            leave_all_rooms(St)
    end.

%%--------------------------------------------------------------------
%% Process a pending stream (waiting for join command)
%%--------------------------------------------------------------------

process_pending_stream(St, Stream, Buf) when byte_size(Buf) < 4 ->
    Streams = St#client.streams,
    St#client{streams = Streams#{Stream => {pending, Buf}}};
process_pending_stream(St, Stream, <<Len:32/big, Rest/binary>> = Buf)
  when byte_size(Rest) < Len ->
    Streams = St#client.streams,
    St#client{streams = Streams#{Stream => {pending, Buf}}};
process_pending_stream(St, Stream, <<Len:32/big, Rest/binary>>) ->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    case catch json:decode(Payload) of
        #{<<"cmd">> := <<"join">>, <<"room">> := RoomName, <<"nick">> := Nick} ->
            RoomPid = get_or_create_room(RoomName),
            RoomPid ! {join, self(), Nick},
            receive
                {joined, Members} ->
                    send_event_on(Stream, #{<<"ev">> => <<"joined">>,
                                            <<"room">> => RoomName,
                                            <<"members">> => Members}),
                    io:format("[chat] ~s joined room ~s (stream ~p)~n",
                              [Nick, RoomName, Stream]),
                    Streams = St#client.streams,
                    St#client{
                        nick = Nick,
                        streams = Streams#{Stream => {RoomName, RoomPid, Tail}}
                    }
            after 5000 ->
                send_event_on(Stream, #{<<"ev">> => <<"error">>,
                                        <<"text">> => <<"join timeout">>}),
                Streams = St#client.streams,
                St#client{streams = Streams#{Stream => {pending, Tail}}}
            end;
        _ ->
            send_event_on(Stream, #{<<"ev">> => <<"error">>,
                                    <<"text">> => <<"first command must be join">>}),
            Streams = St#client.streams,
            St#client{streams = Streams#{Stream => {pending, Tail}}}
    end.

%%--------------------------------------------------------------------
%% Process frames on a stream that's bound to a room
%%--------------------------------------------------------------------

process_room_frames(St, _Stream, _RoomName, _RoomPid, Buf) when byte_size(Buf) < 4 ->
    {Buf, St};
process_room_frames(St, _Stream, _RoomName, _RoomPid, <<Len:32/big, Rest/binary>> = Buf)
  when byte_size(Rest) < Len ->
    {Buf, St};
process_room_frames(St, Stream, RoomName, RoomPid, <<Len:32/big, Rest/binary>>) ->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    St2 = handle_room_command(St, Stream, RoomName, RoomPid, Payload),
    process_room_frames(St2, Stream, RoomName, RoomPid, Tail).

handle_room_command(St, _Stream, _RoomName, RoomPid, Payload) ->
    case catch json:decode(Payload) of
        #{<<"cmd">> := <<"msg">>, <<"text">> := Text} ->
            RoomPid ! {chat, self(), St#client.nick, Text},
            St;
        _ ->
            St
    end.

%%--------------------------------------------------------------------
%% Send a JSON event on a specific stream (length-prefixed)
%%--------------------------------------------------------------------

send_event_on(Stream, Msg) ->
    Json = json:encode(Msg),
    Bin = iolist_to_binary(Json),
    Len = byte_size(Bin),
    io:format("[chat] Sending on ~p: ~s~n", [Stream, Bin]),
    gen_quic:send(Stream, <<Len:32/big, Bin/binary>>).

%%--------------------------------------------------------------------
%% Find the stream for a given room and send an event
%%--------------------------------------------------------------------

send_to_room_stream(#client{streams = Streams}, RoomName, Msg) ->
    maps:foreach(fun(Stream, {Name, _Pid, _Buf}) when Name =:= RoomName ->
        send_event_on(Stream, Msg);
    (_Stream, _Info) ->
        ok
    end, Streams).

%%--------------------------------------------------------------------
%% Handle stream close — leave the associated room
%%--------------------------------------------------------------------

handle_stream_close(St, Stream) ->
    case maps:get(Stream, St#client.streams, undefined) of
        undefined ->
            St;
        {pending, _Buf} ->
            Streams = maps:remove(Stream, St#client.streams),
            St#client{streams = Streams};
        {RoomName, RoomPid, _Buf} ->
            RoomPid ! {leave, self(), St#client.nick},
            io:format("[chat] ~s left room ~s (stream closed)~n",
                      [St#client.nick, RoomName]),
            Streams = maps:remove(Stream, St#client.streams),
            St#client{streams = Streams}
    end.

%%--------------------------------------------------------------------
%% Leave all rooms (connection closing)
%%--------------------------------------------------------------------

leave_all_rooms(#client{streams = Streams, nick = Nick}) ->
    maps:foreach(fun(_Stream, {_RoomName, RoomPid, _Buf}) ->
        RoomPid ! {leave, self(), Nick};
    (_Stream, _) ->
        ok
    end, Streams),
    ok.

%%--------------------------------------------------------------------
%% Room helpers
%%--------------------------------------------------------------------

get_or_create_room(RoomName) ->
    quic_chat_rooms ! {get_or_create, self(), RoomName},
    receive
        {room_pid, Pid} -> Pid
    after 5000 ->
        error(room_manager_timeout)
    end.

%%--------------------------------------------------------------------
%% Room manager: maps room names to room pids
%%--------------------------------------------------------------------

room_manager(Rooms) ->
    receive
        {get_or_create, From, Name} ->
            case maps:get(Name, Rooms, undefined) of
                undefined ->
                    Pid = spawn(fun() -> room_proc(Name, #{}) end),
                    monitor(process, Pid),
                    io:format("[chat] Created room ~s (~p)~n", [Name, Pid]),
                    From ! {room_pid, Pid},
                    room_manager(Rooms#{Name => Pid});
                Pid ->
                    From ! {room_pid, Pid},
                    room_manager(Rooms)
            end;
        {'DOWN', _Ref, process, Pid, _Reason} ->
            Rooms2 = maps:filter(fun(_N, P) -> P =/= Pid end, Rooms),
            room_manager(Rooms2)
    end.

%%--------------------------------------------------------------------
%% Room process: manages members and broadcasts messages
%%
%% Members map: #{Pid => Nick}
%%
%% Broadcasts include the room name so the connection handler
%% can route to the correct stream.
%%--------------------------------------------------------------------

room_proc(RoomName, Members) ->
    receive
        {join, Pid, Nick} ->
            %% Notify existing members
            maps:foreach(fun(P, _N) ->
                P ! {room_msg, RoomName, #{<<"ev">> => <<"enter">>,
                                           <<"nick">> => Nick}}
            end, Members),
            %% Send current member list to the joiner
            Nicks = maps:values(Members),
            Pid ! {joined, Nicks},
            monitor(process, Pid),
            room_proc(RoomName, Members#{Pid => Nick});

        {leave, Pid, Nick} ->
            Members2 = maps:remove(Pid, Members),
            broadcast(Members2, RoomName, #{<<"ev">> => <<"left">>,
                                            <<"nick">> => Nick}),
            io:format("[chat] ~s left room ~s~n", [Nick, RoomName]),
            room_proc(RoomName, Members2);

        {chat, FromPid, Nick, Text} ->
            Msg = #{<<"ev">> => <<"msg">>,
                    <<"nick">> => Nick,
                    <<"text">> => Text},
            %% Send to all members except the sender
            maps:foreach(fun(P, _N) when P =/= FromPid ->
                P ! {room_msg, RoomName, Msg};
            (_P, _N) -> ok
            end, Members),
            room_proc(RoomName, Members);

        {'DOWN', _Ref, process, Pid, _Reason} ->
            case maps:get(Pid, Members, undefined) of
                undefined ->
                    room_proc(RoomName, Members);
                Nick ->
                    Members2 = maps:remove(Pid, Members),
                    broadcast(Members2, RoomName, #{<<"ev">> => <<"left">>,
                                                    <<"nick">> => Nick}),
                    io:format("[chat] ~s disconnected from ~s~n", [Nick, RoomName]),
                    room_proc(RoomName, Members2)
            end
    end.

broadcast(Members, RoomName, Msg) ->
    maps:foreach(fun(P, _N) -> P ! {room_msg, RoomName, Msg} end, Members).
