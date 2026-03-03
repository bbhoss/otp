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

%% QUIC Integration Test Suite
%%
%% Tests the full QUIC stack using the gen_quic API, demonstrating
%% echo server/client patterns that exercise the complete protocol.

-module(quic_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("../src/quic.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    echo_test/1,
    multi_stream_test/1,
    active_echo_test/1,
    datagram_echo_test/1,
    connection_info_test/1,
    transport_params_roundtrip/1,
    packet_encode_decode/1
]).

all() ->
    [{group, unit_tests}, {group, integration_tests}].

groups() ->
    [{unit_tests, [parallel], [
        transport_params_roundtrip,
        packet_encode_decode
    ]},
     {integration_tests, [sequence], [
        echo_test,
        multi_stream_test,
        active_echo_test,
        datagram_echo_test,
        connection_info_test
    ]}].

init_per_suite(Config) ->
    %% Generate test certificates
    PrivDir = proplists:get_value(priv_dir, Config),
    CertFile = filename:join(PrivDir, "cert.pem"),
    KeyFile = filename:join(PrivDir, "key.pem"),

    Cmd = io_lib:format(
        "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 "
        "-nodes -keyout ~s -out ~s -days 1 -subj '/CN=localhost' 2>/dev/null",
        [KeyFile, CertFile]),
    os:cmd(lists:flatten(Cmd)),

    %% Ensure quic app is started
    application:ensure_all_started(crypto),
    application:ensure_all_started(public_key),

    [{certfile, CertFile}, {keyfile, KeyFile} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Pick a random port for each test
    Port = 14000 + rand:uniform(1000),
    [{port, Port} | Config].

end_per_testcase(_TestCase, _Config) ->
    ok.

%% ===================================================================
%% Unit Tests
%% ===================================================================

transport_params_roundtrip(_Config) ->
    Params = quic_transport_params:default_client(),
    Bin = quic_transport_params:encode(Params),
    {ok, Decoded} = quic_transport_params:decode(Bin),
    %% Check key fields survived the roundtrip
    true = (Params#transport_params.initial_max_data =:=
            Decoded#transport_params.initial_max_data),
    true = (Params#transport_params.initial_max_streams_bidi =:=
            Decoded#transport_params.initial_max_streams_bidi),
    true = (Params#transport_params.max_idle_timeout =:=
            Decoded#transport_params.max_idle_timeout),
    ok.

packet_encode_decode(_Config) ->
    DCID = <<1,2,3,4,5,6,7,8>>,
    SCID = <<9,10,11,12,13,14,15,16>>,

    %% Initial packet
    Payload = <<"test payload">>,
    Bin = quic_packet:encode_initial(DCID, SCID, <<>>, 0, Payload),
    {ok, Pkt, _Rest} = quic_packet:decode_header(Bin),
    initial = Pkt#quic_packet.type,
    DCID = Pkt#quic_packet.dcid,
    SCID = Pkt#quic_packet.scid,

    %% Version Negotiation
    VN = quic_packet:encode_version_negotiation(DCID, SCID, [1, 16#6b3343cf]),
    {ok, VNPkt, <<>>} = quic_packet:decode_header(VN),
    version_negotiation = VNPkt#quic_packet.type,
    [1, 16#6b3343cf] = VNPkt#quic_packet.payload,

    %% Packet number encoding/decoding
    {TruncPN, PNLen} = quic_packet:encode_packet_number(100, 90),
    FullPN = quic_packet:decode_packet_number(TruncPN, PNLen, 90),
    100 = FullPN,

    ok.

%% ===================================================================
%% Integration Tests - Echo Pattern using gen_quic
%% ===================================================================

echo_test(Config) ->
    Port = ?config(port, Config),
    CertFile = ?config(certfile, Config),
    KeyFile = ?config(keyfile, Config),

    %% Start QUIC application
    ok = quic:start(),

    %% Start echo server
    {ok, L} = gen_quic:listen(Port, [
        binary,
        {active, false},
        {certfile, CertFile},
        {keyfile, KeyFile},
        {alpn, [<<"echo">>]},
        {initial_max_streams_bidi, 100},
        {initial_max_data, 1048576},
        {initial_max_stream_data_bidi_local, 65536},
        {initial_max_stream_data_bidi_remote, 65536}
    ]),

    %% Spawn server acceptor
    _ServerPid = spawn_link(fun() -> echo_server(L) end),

    %% Client connects
    {ok, Conn} = gen_quic:connect("localhost", Port, [
        binary,
        {active, false},
        {alpn, [<<"echo">>]},
        {verify, verify_none}
    ], 5000),

    %% Open stream and exchange data
    {ok, Stream} = gen_quic:open_stream(Conn),
    TestData = <<"Hello, QUIC! This is an echo test.">>,
    ok = gen_quic:send(Stream, TestData),
    {ok, TestData} = gen_quic:recv(Stream, byte_size(TestData), 5000),

    %% Clean shutdown
    ok = gen_quic:close_stream(Stream),
    ok = gen_quic:close(Conn),
    ok = gen_quic:close(L),
    ok.

multi_stream_test(Config) ->
    Port = ?config(port, Config),
    CertFile = ?config(certfile, Config),
    KeyFile = ?config(keyfile, Config),

    ok = quic:start(),

    {ok, L} = gen_quic:listen(Port, [
        binary, {active, false},
        {certfile, CertFile}, {keyfile, KeyFile},
        {alpn, [<<"echo">>]}
    ]),

    _ServerPid = spawn_link(fun() -> echo_server(L) end),

    {ok, Conn} = gen_quic:connect("localhost", Port, [
        binary, {active, false},
        {alpn, [<<"echo">>]}, {verify, verify_none}
    ], 5000),

    %% Open multiple streams
    {ok, S1} = gen_quic:open_stream(Conn),
    {ok, S2} = gen_quic:open_stream(Conn),
    {ok, S3} = gen_quic:open_stream(Conn),

    %% Send on all streams
    ok = gen_quic:send(S1, <<"stream one">>),
    ok = gen_quic:send(S2, <<"stream two">>),
    ok = gen_quic:send(S3, <<"stream three">>),

    %% Receive from each stream independently
    {ok, <<"stream one">>} = gen_quic:recv(S1, 10, 5000),
    {ok, <<"stream two">>} = gen_quic:recv(S2, 10, 5000),
    {ok, <<"stream three">>} = gen_quic:recv(S3, 12, 5000),

    gen_quic:close(Conn),
    gen_quic:close(L),
    ok.

active_echo_test(Config) ->
    Port = ?config(port, Config),
    CertFile = ?config(certfile, Config),
    KeyFile = ?config(keyfile, Config),

    ok = quic:start(),

    {ok, L} = gen_quic:listen(Port, [
        binary, {active, true},
        {certfile, CertFile}, {keyfile, KeyFile},
        {alpn, [<<"echo">>]}
    ]),

    spawn_link(fun() -> active_echo_server(L) end),

    {ok, Conn} = gen_quic:connect("localhost", Port, [
        binary, {active, true},
        {alpn, [<<"echo">>]}, {verify, verify_none}
    ], 5000),

    {ok, Stream} = gen_quic:open_stream(Conn),
    ok = gen_quic:send(Stream, <<"active mode echo">>),

    receive
        {quic, Stream, <<"active mode echo">>} -> ok
    after 5000 ->
        ct:fail(active_echo_timeout)
    end,

    gen_quic:close(Conn),
    gen_quic:close(L),
    ok.

datagram_echo_test(Config) ->
    Port = ?config(port, Config),
    CertFile = ?config(certfile, Config),
    KeyFile = ?config(keyfile, Config),

    ok = quic:start(),

    {ok, L} = gen_quic:listen(Port, [
        binary, {active, false},
        {certfile, CertFile}, {keyfile, KeyFile},
        {alpn, [<<"echo">>]},
        {max_datagram_frame_size, 1200}
    ]),

    spawn_link(fun() -> datagram_echo_server(L) end),

    {ok, Conn} = gen_quic:connect("localhost", Port, [
        binary, {active, false},
        {alpn, [<<"echo">>]}, {verify, verify_none},
        {max_datagram_frame_size, 1200}
    ], 5000),

    ok = gen_quic:send_datagram(Conn, <<"ping">>),
    {ok, <<"ping">>} = gen_quic:recv_datagram(Conn, 5000),

    gen_quic:close(Conn),
    gen_quic:close(L),
    ok.

connection_info_test(Config) ->
    Port = ?config(port, Config),
    CertFile = ?config(certfile, Config),
    KeyFile = ?config(keyfile, Config),

    ok = quic:start(),

    {ok, L} = gen_quic:listen(Port, [
        binary, {active, false},
        {certfile, CertFile}, {keyfile, KeyFile},
        {alpn, [<<"echo">>]}
    ]),

    spawn_link(fun() -> echo_server(L) end),

    {ok, Conn} = gen_quic:connect("localhost", Port, [
        binary, {active, false},
        {alpn, [<<"echo">>]}, {verify, verify_none}
    ], 5000),

    {ok, Info} = gen_quic:connection_info(Conn),
    true = is_map(Info),

    gen_quic:close(Conn),
    gen_quic:close(L),
    ok.

%% ===================================================================
%% Echo Server Helpers
%% ===================================================================

echo_server(L) ->
    {ok, Conn} = gen_quic:accept(L),
    spawn_link(fun() -> echo_server(L) end),
    echo_connection(Conn).

echo_connection(Conn) ->
    case gen_quic:accept_stream(Conn, 30000) of
        {ok, Stream} ->
            spawn_link(fun() -> echo_stream(Stream) end),
            echo_connection(Conn);
        {error, closed} ->
            ok;
        {error, timeout} ->
            gen_quic:close(Conn)
    end.

echo_stream(Stream) ->
    case gen_quic:recv(Stream, 0, 30000) of
        {ok, Data} ->
            ok = gen_quic:send(Stream, Data),
            echo_stream(Stream);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            gen_quic:close_stream(Stream)
    end.

active_echo_server(L) ->
    {ok, Conn} = gen_quic:accept(L),
    spawn_link(fun() -> active_echo_server(L) end),
    active_echo_conn_loop(Conn, #{}).

active_echo_conn_loop(Conn, Streams) ->
    receive
        {quic_stream_opened, Conn, Stream} ->
            active_echo_conn_loop(Conn, Streams#{Stream => true});
        {quic, Stream, Data} ->
            gen_quic:send(Stream, Data),
            active_echo_conn_loop(Conn, Streams);
        {quic_stream_closed, _Stream} ->
            active_echo_conn_loop(Conn, Streams);
        {quic_closed, Conn} ->
            ok
    end.

datagram_echo_server(L) ->
    {ok, Conn} = gen_quic:accept(L),
    datagram_echo_loop(Conn).

datagram_echo_loop(Conn) ->
    case gen_quic:recv_datagram(Conn, 30000) of
        {ok, Data} ->
            gen_quic:send_datagram(Conn, Data),
            datagram_echo_loop(Conn);
        {error, _} ->
            ok
    end.
