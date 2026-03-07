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

%% QUIC Interop Client - HTTP/0.9 file downloader for quic-interop-runner
%%
%% Speaks the "hq-interop" ALPN protocol:
%%   Opens stream, sends "GET /path\r\n", reads response bytes to file.
%%
%% Environment variables:
%%   TESTCASE  - test case name
%%   REQUESTS  - space-separated URLs to download
%%   SSLKEYLOGFILE - path to write TLS key log

-module(quic_interop_client).

-export([main/1]).

main(Args) ->
    TestCase = os:getenv("TESTCASE"),
    io:format("[interop-client] TESTCASE=~s~n", [TestCase]),

    %% Check if we support this test case
    case supported(TestCase) of
        false ->
            io:format("[interop-client] Unsupported test case: ~s~n", [TestCase]),
            halt(127);
        true ->
            ok
    end,

    %% Configure SSLKEYLOGFILE if set
    case os:getenv("SSLKEYLOGFILE") of
        false -> ok;
        KeyLogFile ->
            io:format("[interop-client] SSLKEYLOGFILE=~s~n", [KeyLogFile]),
            application:set_env(quic, sslkeylogfile, KeyLogFile)
    end,

    %% URLs come from command-line args (REQUESTS env var is passed as args)
    URLs = Args,
    io:format("[interop-client] URLs: ~p~n", [URLs]),

    case URLs of
        [] ->
            io:format("[interop-client] No URLs provided~n"),
            halt(1);
        _ ->
            ok
    end,

    %% Group URLs by host:port to reuse connections
    Groups = group_urls(URLs),

    %% For multiconnect, use separate connections per URL
    case TestCase of
        "multiconnect" ->
            run_multi_connect(URLs, TestCase);
        _ ->
            run_grouped(Groups, TestCase)
    end.

run_grouped(Groups, TestCase) ->
    maps:foreach(fun({Host, Port}, Paths) ->
        download_paths(Host, Port, Paths, TestCase)
    end, Groups),
    io:format("[interop-client] All downloads complete~n"),
    halt(0).

run_multi_connect(URLs, TestCase) ->
    lists:foreach(fun(URL) ->
        {Host, Port, Path} = parse_url(URL),
        download_paths(Host, Port, [Path], TestCase)
    end, URLs),
    io:format("[interop-client] All downloads complete~n"),
    halt(0).

download_paths(Host, Port, Paths, TestCase) ->
    Opts = [binary,
            {alpn, [<<"hq-interop">>]},
            {verify, verify_none}]
           ++ test_case_opts(TestCase),

    io:format("[interop-client] Connecting to ~s:~B~n", [Host, Port]),
    case gen_quic:connect(Host, Port, Opts, 30000) of
        {ok, Conn} ->
            lists:foreach(fun(Path) ->
                download_one(Conn, Path)
            end, Paths),
            gen_quic:close(Conn);
        {error, Reason} ->
            io:format("[interop-client] Connect failed: ~p~n", [Reason]),
            halt(1)
    end.

download_one(Conn, Path) ->
    io:format("[interop-client] GET ~s~n", [Path]),
    {ok, Stream} = gen_quic:open_stream(Conn),
    Request = <<"GET ", (list_to_binary(Path))/binary, "\r\n">>,
    ok = gen_quic:send(Stream, Request),
    ok = gen_quic:close_stream(Stream),
    %% Read response
    Data = read_all(Stream, []),
    %% Save to /downloads/path
    OutPath = "/downloads" ++ Path,
    ok = filelib:ensure_dir(OutPath),
    ok = file:write_file(OutPath, Data),
    io:format("[interop-client] Saved ~s (~B bytes)~n", [OutPath, byte_size(Data)]).

read_all(Stream, Acc) ->
    case gen_quic:recv(Stream, 0, 30000) of
        {ok, Data} ->
            read_all(Stream, [Data | Acc]);
        {error, closed} ->
            iolist_to_binary(lists:reverse(Acc));
        {error, timeout} ->
            iolist_to_binary(lists:reverse(Acc));
        {error, _Reason} ->
            iolist_to_binary(lists:reverse(Acc))
    end.

%% URL parsing
parse_url(URL) ->
    %% URLs look like "https://server4:443/path"
    URLStr = case URL of
        B when is_binary(B) -> binary_to_list(B);
        L when is_list(L) -> L
    end,
    %% Strip scheme
    NoScheme = case string:prefix(URLStr, "https://") of
        nomatch -> URLStr;
        Rest -> Rest
    end,
    %% Split host:port/path
    {HostPort, Path} = case string:chr(NoScheme, $/) of
        0 -> {NoScheme, "/"};
        Pos -> {string:substr(NoScheme, 1, Pos - 1),
                string:substr(NoScheme, Pos)}
    end,
    %% Split host:port
    {Host, Port} = case string:chr(HostPort, $:) of
        0 -> {HostPort, 443};
        PPos -> {string:substr(HostPort, 1, PPos - 1),
                 list_to_integer(string:substr(HostPort, PPos + 1))}
    end,
    {Host, Port, Path}.

group_urls(URLs) ->
    lists:foldl(fun(URL, Acc) ->
        {Host, Port, Path} = parse_url(URL),
        Key = {Host, Port},
        Existing = maps:get(Key, Acc, []),
        maps:put(Key, Existing ++ [Path], Acc)
    end, #{}, URLs).

%% Test case support (same as server)
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
test_case_opts("chacha20") ->
    [{cipher_suites, [chacha20_poly1305_sha256]}];
test_case_opts(_) ->
    [].
