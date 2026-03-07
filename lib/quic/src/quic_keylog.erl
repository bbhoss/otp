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

%% QUIC SSLKEYLOGFILE support (NSS Key Log Format)
%%
%% Writes TLS 1.3 key material in the standard NSS key log format,
%% compatible with Wireshark and the quic-interop-runner pcap analysis.
%%
%% Format per line:
%%   LABEL CLIENT_RANDOM SECRET
%%
%% Where LABEL is one of:
%%   CLIENT_HANDSHAKE_TRAFFIC_SECRET
%%   SERVER_HANDSHAKE_TRAFFIC_SECRET
%%   CLIENT_TRAFFIC_SECRET_0
%%   SERVER_TRAFFIC_SECRET_0

-module(quic_keylog).

-export([
    log_handshake_secrets/3,
    log_application_secrets/3
]).

%% @doc Log handshake traffic secrets.
-spec log_handshake_secrets(binary(), binary(), binary()) -> ok.
log_handshake_secrets(ClientRandom, ClientHSSecret, ServerHSSecret) ->
    case get_keylog_file() of
        undefined -> ok;
        File ->
            CRHex = bin_to_hex(ClientRandom),
            append_line(File, ["CLIENT_HANDSHAKE_TRAFFIC_SECRET ", CRHex, " ",
                               bin_to_hex(ClientHSSecret)]),
            append_line(File, ["SERVER_HANDSHAKE_TRAFFIC_SECRET ", CRHex, " ",
                               bin_to_hex(ServerHSSecret)])
    end.

%% @doc Log application traffic secrets.
-spec log_application_secrets(binary(), binary(), binary()) -> ok.
log_application_secrets(ClientRandom, ClientAppSecret, ServerAppSecret) ->
    case get_keylog_file() of
        undefined -> ok;
        File ->
            CRHex = bin_to_hex(ClientRandom),
            append_line(File, ["CLIENT_TRAFFIC_SECRET_0 ", CRHex, " ",
                               bin_to_hex(ClientAppSecret)]),
            append_line(File, ["SERVER_TRAFFIC_SECRET_0 ", CRHex, " ",
                               bin_to_hex(ServerAppSecret)])
    end.

%% Internal

get_keylog_file() ->
    case application:get_env(quic, sslkeylogfile) of
        {ok, File} -> File;
        undefined -> undefined
    end.

append_line(File, IOList) ->
    Line = [IOList, "\n"],
    file:write_file(File, iolist_to_binary(Line), [append]).

bin_to_hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
