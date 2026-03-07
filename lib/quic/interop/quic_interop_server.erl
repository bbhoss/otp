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

%% QUIC Interop Server - HTTP/0.9 file server for quic-interop-runner
%%
%% Speaks the "hq-interop" ALPN protocol:
%%   Client opens stream, sends "GET /path\r\n"
%%   Server responds with raw file bytes, then closes stream.
%%
%% Environment variables:
%%   TESTCASE  - test case name (handshake, transfer, retry, etc.)
%%   SSLKEYLOGFILE - path to write TLS key log (for pcap analysis)
%%   QLOGDIR   - directory for qlog output (not yet supported)

-module(quic_interop_server).

-export([main/1]).

main(_Args) ->
    TestCase = os:getenv("TESTCASE"),
    io:format("[interop-server] TESTCASE=~s~n", [TestCase]),

    %% Check if we support this test case
    case supported(TestCase) of
        false ->
            io:format("[interop-server] Unsupported test case: ~s~n", [TestCase]),
            halt(127);
        true ->
            ok
    end,

    CertFile = "/certs/cert.pem",
    KeyFile = "/certs/priv.key",

    %% Configure SSLKEYLOGFILE if set
    case os:getenv("SSLKEYLOGFILE") of
        false -> ok;
        KeyLogFile ->
            io:format("[interop-server] SSLKEYLOGFILE=~s~n", [KeyLogFile]),
            application:set_env(quic, sslkeylogfile, KeyLogFile)
    end,

    Opts = [binary,
            {certfile, CertFile},
            {keyfile, KeyFile},
            {alpn, [<<"hq-interop">>]},
            {verify, verify_none}]
           ++ test_case_opts(TestCase),

    {ok, Listener} = gen_quic:listen(443, Opts),
    io:format("[interop-server] Listening on port 443~n"),

    accept_loop(Listener).

accept_loop(Listener) ->
    case gen_quic:accept(Listener) of
        {ok, Conn} ->
            Pid = spawn(fun() -> handle_connection(Conn) end),
            gen_quic:controlling_process(Conn, Pid),
            accept_loop(Listener);
        {error, Reason} ->
            io:format("[interop-server] Accept error: ~p~n", [Reason]),
            accept_loop(Listener)
    end.

handle_connection(Conn) ->
    handle_streams(Conn).

handle_streams(Conn) ->
    case gen_quic:accept_stream(Conn, 60000) of
        {ok, Stream} ->
            spawn(fun() -> handle_stream(Stream) end),
            handle_streams(Conn);
        {error, closed} ->
            ok;
        {error, timeout} ->
            ok;
        {error, Reason} ->
            io:format("[interop-server] Stream accept error: ~p~n", [Reason]),
            ok
    end.

handle_stream(Stream) ->
    %% Read the HTTP/0.9 request: "GET /path\r\n"
    case read_request(Stream, <<>>) of
        {ok, Path} ->
            serve_file(Stream, Path);
        {error, Reason} ->
            io:format("[interop-server] Request error: ~p~n", [Reason])
    end.

read_request(Stream, Acc) ->
    case gen_quic:recv(Stream, 0, 10000) of
        {ok, Data} ->
            Combined = <<Acc/binary, Data/binary>>,
            case binary:match(Combined, <<"\r\n">>) of
                {Pos, _} ->
                    Line = binary:part(Combined, 0, Pos),
                    parse_request(Line);
                nomatch ->
                    %% Check for just \n
                    case binary:match(Combined, <<"\n">>) of
                        {Pos2, _} ->
                            Line = binary:part(Combined, 0, Pos2),
                            parse_request(Line);
                        nomatch ->
                            read_request(Stream, Combined)
                    end
            end;
        {error, closed} ->
            %% Peer closed write side, parse what we have
            case byte_size(Acc) > 0 of
                true -> parse_request(Acc);
                false -> {error, no_request}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parse_request(Line) ->
    case Line of
        <<"GET ", PathAndRest/binary>> ->
            Path = string:trim(PathAndRest, trailing),
            {ok, Path};
        _ ->
            {error, {bad_request, Line}}
    end.

serve_file(Stream, Path) ->
    %% Path comes as "/filename", serve from /www
    FilePath = <<"/www", Path/binary>>,
    FilePathStr = binary_to_list(FilePath),
    case file:read_file(FilePathStr) of
        {ok, Data} ->
            send_all(Stream, Data),
            gen_quic:close_stream(Stream);
        {error, Reason} ->
            io:format("[interop-server] File not found: ~s (~p)~n",
                      [FilePathStr, Reason]),
            gen_quic:close_stream(Stream)
    end.

%% Send data in chunks to respect stream-level flow control.
%% The transport layer handles packet fragmentation, but we must
%% chunk at the application level because gen_quic:send silently
%% truncates to the available flow control window.
send_all(_Stream, <<>>) ->
    ok;
send_all(Stream, Data) ->
    ChunkSize = min(byte_size(Data), 32768),
    <<Chunk:ChunkSize/binary, Rest/binary>> = Data,
    case gen_quic:send(Stream, Chunk) of
        ok ->
            send_all(Stream, Rest);
        {error, flow_control_blocked} ->
            %% Wait for peer to open flow control window
            timer:sleep(10),
            send_all(Stream, Data);
        {error, Reason} ->
            {error, Reason}
    end.

%% Test case support
supported("handshake") -> true;
supported("transfer") -> true;
supported("retry") -> true;
supported("multihandshake") -> true;
supported("multiplexing") -> true;
supported("longrtt") -> true;
supported("chacha20") -> true;
supported("v2") -> true;
supported("ecn") -> true;
supported("ipv6") -> true;
supported("handshakeloss") -> true;
supported("transferloss") -> true;
supported("handshakecorruption") -> true;
supported("transfercorruption") -> true;
supported("multiconnect") -> true;
supported(_) -> false.

%% Per-test-case options
test_case_opts("retry") ->
    [{retry, true}];
test_case_opts("chacha20") ->
    [{cipher_suites, [chacha20_poly1305_sha256]}];
test_case_opts(_) ->
    [].
