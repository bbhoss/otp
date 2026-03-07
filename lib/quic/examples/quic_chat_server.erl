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
%% Pull-model architecture with QUIC stream multiplexing.
%% Each chat room is carried on its own QUIC bidirectional stream.
%% Each stream gets its own handler process with a recv proxy.
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
-export([acceptor_loop/1, connection_handler/1, room_proc/2]).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

start(Port, CertFile, KeyFile) ->
    RoomMgr = spawn_link(fun() -> room_manager(#{}) end),
    register(quic_chat_rooms, RoomMgr),
    {ok, L} = gen_quic:listen(Port, [
        binary,
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
            Handler = spawn(fun() -> connection_handler(Conn) end),
            gen_quic:controlling_process(Conn, Handler),
            acceptor_loop(Listener);
        {error, Reason} ->
            io:format("[chat] Accept error: ~p~n", [Reason])
    end.

%%--------------------------------------------------------------------
%% Connection handler: accepts streams, spawns stream handlers
%%--------------------------------------------------------------------

connection_handler(Conn) ->
    case gen_quic:accept_stream(Conn, infinity) of
        {ok, Stream} ->
            io:format("[chat] Stream opened: ~p~n", [Stream]),
            spawn(fun() -> stream_handler(Stream) end),
            connection_handler(Conn);
        {error, closed} ->
            io:format("[chat] Connection closed~n")
    end.

%%--------------------------------------------------------------------
%% Stream handler: one process per stream (per room)
%%
%% Uses a recv_proxy process that blocks on gen_quic:recv and
%% forwards data, so the handler can receive both stream data
%% and room broadcast messages concurrently.
%%--------------------------------------------------------------------

stream_handler(Stream) ->
    Self = self(),
    spawn_link(fun() -> recv_proxy(Self, Stream) end),
    pending_join(Stream, <<>>).

recv_proxy(Handler, Stream) ->
    case gen_quic:recv(Stream, 0, infinity) of
        {ok, Data} ->
            Handler ! {stream_data, Data},
            recv_proxy(Handler, Stream);
        {error, Reason} ->
            Handler ! {stream_error, Reason}
    end.

%%--------------------------------------------------------------------
%% Pending join: waiting for the first message (join command)
%%--------------------------------------------------------------------

pending_join(Stream, Buf) ->
    case try_parse_frame(Buf) of
        {ok, Payload, Tail} ->
            case catch json:decode(Payload) of
                #{<<"cmd">> := <<"join">>, <<"room">> := RoomName, <<"nick">> := Nick} ->
                    RoomPid = get_or_create_room(RoomName),
                    RoomPid ! {join, self(), Nick},
                    receive
                        {joined, Members} ->
                            send_event(Stream, #{<<"ev">> => <<"joined">>,
                                                  <<"room">> => RoomName,
                                                  <<"members">> => Members}),
                            io:format("[chat] ~s joined room ~s~n", [Nick, RoomName]),
                            room_loop(Stream, RoomName, RoomPid, Nick, Tail)
                    after 5000 ->
                        send_event(Stream, #{<<"ev">> => <<"error">>,
                                              <<"text">> => <<"join timeout">>}),
                        pending_join(Stream, Tail)
                    end;
                _ ->
                    send_event(Stream, #{<<"ev">> => <<"error">>,
                                          <<"text">> => <<"first command must be join">>}),
                    pending_join(Stream, Tail)
            end;
        need_more ->
            receive
                {stream_data, Data} ->
                    pending_join(Stream, <<Buf/binary, Data/binary>>);
                {stream_error, _} ->
                    ok
            end
    end.

%%--------------------------------------------------------------------
%% Room loop: stream is bound to a room, handle chat + broadcasts
%%--------------------------------------------------------------------

room_loop(Stream, RoomName, RoomPid, Nick, Buf) ->
    case try_parse_frame(Buf) of
        {ok, Payload, Tail} ->
            handle_room_command(RoomPid, Nick, Payload),
            room_loop(Stream, RoomName, RoomPid, Nick, Tail);
        need_more ->
            receive
                {stream_data, Data} ->
                    room_loop(Stream, RoomName, RoomPid, Nick,
                              <<Buf/binary, Data/binary>>);
                {room_msg, RoomName, Msg} ->
                    send_event(Stream, Msg),
                    room_loop(Stream, RoomName, RoomPid, Nick, Buf);
                {stream_error, _} ->
                    RoomPid ! {leave, self(), Nick},
                    io:format("[chat] ~s left room ~s~n", [Nick, RoomName])
            end
    end.

handle_room_command(RoomPid, Nick, Payload) ->
    case catch json:decode(Payload) of
        #{<<"cmd">> := <<"msg">>, <<"text">> := Text} ->
            RoomPid ! {chat, self(), Nick, Text};
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% Frame parsing: length-prefixed JSON
%%--------------------------------------------------------------------

try_parse_frame(Buf) when byte_size(Buf) < 4 ->
    need_more;
try_parse_frame(<<Len:32/big, Rest/binary>>) when byte_size(Rest) < Len ->
    need_more;
try_parse_frame(<<Len:32/big, Rest/binary>>) ->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    {ok, Payload, Tail}.

%%--------------------------------------------------------------------
%% Send a JSON event on a stream (length-prefixed)
%%--------------------------------------------------------------------

send_event(Stream, Msg) ->
    Json = json:encode(Msg),
    Bin = iolist_to_binary(Json),
    Len = byte_size(Bin),
    io:format("[chat] Sending on ~p: ~s~n", [Stream, Bin]),
    gen_quic:send(Stream, <<Len:32/big, Bin/binary>>).

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
%%--------------------------------------------------------------------

room_proc(RoomName, Members) ->
    receive
        {join, Pid, Nick} ->
            maps:foreach(fun(P, _N) ->
                P ! {room_msg, RoomName, #{<<"ev">> => <<"enter">>,
                                           <<"nick">> => Nick}}
            end, Members),
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
