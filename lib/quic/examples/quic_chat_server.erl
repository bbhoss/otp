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
%% Demonstrates gen_quic active mode with a real application protocol.
%%
%% Protocol (length-prefixed JSON on a single bidirectional stream):
%%
%%   Wire format:  <<Length:32/big, JSON:Length/binary>>
%%
%%   Client -> Server:
%%     {"cmd":"join",  "room":"lobby",  "nick":"alice"}
%%     {"cmd":"msg",   "text":"hello everyone"}
%%     {"cmd":"leave"}
%%
%%   Server -> Client:
%%     {"ev":"joined",  "room":"lobby",  "members":["bob"]}
%%     {"ev":"msg",     "room":"lobby",  "nick":"bob",  "text":"hi"}
%%     {"ev":"enter",   "room":"lobby",  "nick":"alice"}
%%     {"ev":"left",    "room":"lobby",  "nick":"bob"}
%%     {"ev":"error",   "text":"not in a room"}
%%
%% Usage:
%%   {ok, Pid} = quic_chat_server:start(4433, "cert.pem", "key.pem").
%%   quic_chat_server:stop(Pid).

-module(quic_chat_server).

-export([start/3, stop/1]).

%% Internal exports for spawn_link
-export([acceptor_loop/1, connection_handler/2, room_proc/1]).

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
            spawn_link(fun() -> connection_handler(Conn, undefined) end),
            acceptor_loop(Listener);
        {error, Reason} ->
            io:format("[chat] Accept error: ~p~n", [Reason])
    end.

%%--------------------------------------------------------------------
%% Connection handler: one per QUIC connection, processes chat messages
%%
%% State tracks: the connection, the single control stream, the
%% user's current room pid, nickname, and a recv buffer for
%% reassembling length-prefixed frames.
%%--------------------------------------------------------------------

-record(client, {
    conn,
    stream = undefined,
    room = undefined,      %% {RoomName, RoomPid} | undefined
    nick = undefined,
    buf = <<>>
}).

connection_handler(Conn, _Parent) ->
    client_loop(#client{conn = Conn}).

client_loop(#client{conn = Conn} = St) ->
    receive
        %% A new stream was opened by the peer — this is the control stream
        {quic_stream_opened, Conn, Stream} ->
            io:format("[chat] Stream opened: ~p~n", [Stream]),
            client_loop(St#client{stream = Stream});

        %% Data arrived on the control stream
        {quic, _Stream, Data} ->
            NewBuf = <<(St#client.buf)/binary, Data/binary>>,
            St2 = process_frames(St#client{buf = NewBuf}),
            client_loop(St2);

        %% Room broadcast: a message from another user in our room
        {room_msg, Msg} ->
            send_event(St, Msg),
            client_loop(St);

        %% Stream / connection lifecycle
        {quic_stream_closed, _Stream} ->
            leave_room(St),
            client_loop(St#client{stream = undefined});

        {quic_closed, Conn} ->
            io:format("[chat] Connection closed~n"),
            leave_room(St);

        {quic_error, _Ref, Reason} ->
            io:format("[chat] Error: ~p~n", [Reason]),
            leave_room(St)
    end.

%%--------------------------------------------------------------------
%% Frame parsing: extract complete <<Len:32, Payload:Len/binary>>
%%--------------------------------------------------------------------

process_frames(#client{buf = Buf} = St) when byte_size(Buf) < 4 ->
    St;
process_frames(#client{buf = <<Len:32/big, Rest/binary>>} = St)
  when byte_size(Rest) < Len ->
    St;
process_frames(#client{buf = <<Len:32/big, Rest/binary>>} = St) ->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    St2 = handle_command(St#client{buf = Tail}, Payload),
    process_frames(St2).

%%--------------------------------------------------------------------
%% Command dispatch
%%--------------------------------------------------------------------

handle_command(St, JsonBin) ->
    case catch json:decode(JsonBin) of
        {'EXIT', _} ->
            send_event(St, #{<<"ev">> => <<"error">>,
                             <<"text">> => <<"bad json">>}),
            St;
        Map when is_map(Map) ->
            dispatch(St, Map);
        _ ->
            send_event(St, #{<<"ev">> => <<"error">>,
                             <<"text">> => <<"expected object">>}),
            St
    end.

dispatch(St, #{<<"cmd">> := <<"join">>,
               <<"room">> := RoomName,
               <<"nick">> := Nick}) ->
    %% Leave current room first if any
    leave_room(St),
    RoomPid = get_or_create_room(RoomName),
    RoomPid ! {join, self(), Nick},
    receive
        {joined, Members} ->
            send_event(St, #{<<"ev">> => <<"joined">>,
                             <<"room">> => RoomName,
                             <<"members">> => Members}),
            St#client{room = {RoomName, RoomPid}, nick = Nick}
    after 5000 ->
        send_event(St, #{<<"ev">> => <<"error">>,
                         <<"text">> => <<"join timeout">>}),
        St
    end;

dispatch(St, #{<<"cmd">> := <<"msg">>, <<"text">> := Text}) ->
    case St#client.room of
        {_RoomName, RoomPid} ->
            RoomPid ! {chat, self(), St#client.nick, Text},
            St;
        undefined ->
            send_event(St, #{<<"ev">> => <<"error">>,
                             <<"text">> => <<"not in a room">>}),
            St
    end;

dispatch(St, #{<<"cmd">> := <<"leave">>}) ->
    leave_room(St),
    send_event(St, #{<<"ev">> => <<"left_ok">>}),
    St#client{room = undefined, nick = undefined};

dispatch(St, _Other) ->
    send_event(St, #{<<"ev">> => <<"error">>,
                     <<"text">> => <<"unknown command">>}),
    St.

%%--------------------------------------------------------------------
%% Send a JSON event back to the client (length-prefixed)
%%--------------------------------------------------------------------

send_event(#client{stream = undefined}, _Msg) ->
    ok;
send_event(#client{stream = Stream}, Msg) ->
    Json = json:encode(Msg),
    Len = byte_size(Json),
    gen_quic:send(Stream, <<Len:32/big, Json/binary>>).

%%--------------------------------------------------------------------
%% Room helpers
%%--------------------------------------------------------------------

leave_room(#client{room = undefined}) -> ok;
leave_room(#client{room = {_Name, RoomPid}, nick = Nick}) ->
    RoomPid ! {leave, self(), Nick},
    ok.

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
                    Pid = spawn_link(fun() -> room_proc(#{}) end),
                    io:format("[chat] Created room ~s (~p)~n", [Name, Pid]),
                    From ! {room_pid, Pid},
                    room_manager(Rooms#{Name => Pid});
                Pid ->
                    From ! {room_pid, Pid},
                    room_manager(Rooms)
            end
    end.

%%--------------------------------------------------------------------
%% Room process: manages members and broadcasts messages
%%
%% Members map: #{Pid => Nick}
%%--------------------------------------------------------------------

room_proc(Members) ->
    receive
        {join, Pid, Nick} ->
            %% Notify existing members
            maps:foreach(fun(P, _N) ->
                P ! {room_msg, #{<<"ev">> => <<"enter">>,
                                 <<"nick">> => Nick}}
            end, Members),
            %% Send current member list to the joiner
            Nicks = maps:values(Members),
            Pid ! {joined, Nicks},
            monitor(process, Pid),
            room_proc(Members#{Pid => Nick});

        {leave, Pid, Nick} ->
            Members2 = maps:remove(Pid, Members),
            broadcast(Members2, #{<<"ev">> => <<"left">>,
                                  <<"nick">> => Nick}),
            io:format("[chat] ~s left room~n", [Nick]),
            room_proc(Members2);

        {chat, FromPid, Nick, Text} ->
            Msg = #{<<"ev">> => <<"msg">>,
                    <<"nick">> => Nick,
                    <<"text">> => Text},
            %% Send to all members except the sender
            maps:foreach(fun(P, _N) when P =/= FromPid ->
                P ! {room_msg, Msg};
            (_P, _N) -> ok
            end, Members),
            room_proc(Members);

        {'DOWN', _Ref, process, Pid, _Reason} ->
            case maps:get(Pid, Members, undefined) of
                undefined ->
                    room_proc(Members);
                Nick ->
                    Members2 = maps:remove(Pid, Members),
                    broadcast(Members2, #{<<"ev">> => <<"left">>,
                                          <<"nick">> => Nick}),
                    io:format("[chat] ~s disconnected~n", [Nick]),
                    room_proc(Members2)
            end
    end.

broadcast(Members, Msg) ->
    maps:foreach(fun(P, _N) -> P ! {room_msg, Msg} end, Members).
