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

-module(quic_frame_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([
    padding_frame/1,
    ping_frame/1,
    ack_frame/1,
    reset_stream_frame/1,
    stop_sending_frame/1,
    crypto_frame/1,
    stream_frame/1,
    stream_frame_with_fin/1,
    max_data_frame/1,
    max_stream_data_frame/1,
    max_streams_frame/1,
    connection_close_frame/1,
    connection_close_app_frame/1,
    handshake_done_frame/1,
    new_connection_id_frame/1,
    path_challenge_response_frames/1,
    datagram_frame/1,
    decode_all_frames/1
]).

all() ->
    [{group, encode_decode}].

groups() ->
    [{encode_decode, [parallel], [
        padding_frame,
        ping_frame,
        ack_frame,
        reset_stream_frame,
        stop_sending_frame,
        crypto_frame,
        stream_frame,
        stream_frame_with_fin,
        max_data_frame,
        max_stream_data_frame,
        max_streams_frame,
        connection_close_frame,
        connection_close_app_frame,
        handshake_done_frame,
        new_connection_id_frame,
        path_challenge_response_frames,
        datagram_frame,
        decode_all_frames
    ]}].

padding_frame(_Config) ->
    Bin = quic_frame:encode(padding),
    {ok, padding, <<>>} = quic_frame:decode(Bin),
    %% Multiple padding bytes
    PadBin = quic_frame:encode({padding, 5}),
    5 = byte_size(PadBin),
    {ok, padding, <<>>} = quic_frame:decode(PadBin),
    ok.

ping_frame(_Config) ->
    Bin = quic_frame:encode(ping),
    {ok, ping, <<>>} = quic_frame:decode(Bin),
    ok.

ack_frame(_Config) ->
    %% ACK with largest=100, delay=5, first_range=10
    Bin = quic_frame:encode({ack, 100, 5, [10]}),
    {ok, {ack, 100, 5, [10]}, <<>>} = quic_frame:decode(Bin),
    %% ACK with gap ranges
    Bin2 = quic_frame:encode({ack, 200, 10, [5, {2, 3}]}),
    {ok, {ack, 200, 10, [5, {2, 3}]}, <<>>} = quic_frame:decode(Bin2),
    ok.

reset_stream_frame(_Config) ->
    Bin = quic_frame:encode({reset_stream, 4, 1, 1024}),
    {ok, {reset_stream, 4, 1, 1024}, <<>>} = quic_frame:decode(Bin),
    ok.

stop_sending_frame(_Config) ->
    Bin = quic_frame:encode({stop_sending, 8, 2}),
    {ok, {stop_sending, 8, 2}, <<>>} = quic_frame:decode(Bin),
    ok.

crypto_frame(_Config) ->
    Data = <<"TLS handshake data">>,
    Bin = quic_frame:encode({crypto, 0, Data}),
    {ok, {crypto, 0, Data}, <<>>} = quic_frame:decode(Bin),
    %% With offset
    Bin2 = quic_frame:encode({crypto, 100, Data}),
    {ok, {crypto, 100, Data}, <<>>} = quic_frame:decode(Bin2),
    ok.

stream_frame(_Config) ->
    Data = <<"Hello, QUIC!">>,
    Bin = quic_frame:encode({stream, 0, 0, Data, false}),
    {ok, {stream, 0, 0, Data, false}, <<>>} = quic_frame:decode(Bin),
    %% With offset
    Bin2 = quic_frame:encode({stream, 4, 100, Data, false}),
    {ok, {stream, 4, 100, Data, false}, <<>>} = quic_frame:decode(Bin2),
    ok.

stream_frame_with_fin(_Config) ->
    Data = <<"final data">>,
    Bin = quic_frame:encode({stream, 0, 0, Data, true}),
    {ok, {stream, 0, 0, Data, true}, <<>>} = quic_frame:decode(Bin),
    ok.

max_data_frame(_Config) ->
    Bin = quic_frame:encode({max_data, 1048576}),
    {ok, {max_data, 1048576}, <<>>} = quic_frame:decode(Bin),
    ok.

max_stream_data_frame(_Config) ->
    Bin = quic_frame:encode({max_stream_data, 4, 65536}),
    {ok, {max_stream_data, 4, 65536}, <<>>} = quic_frame:decode(Bin),
    ok.

max_streams_frame(_Config) ->
    Bin1 = quic_frame:encode({max_streams, bidi, 100}),
    {ok, {max_streams, bidi, 100}, <<>>} = quic_frame:decode(Bin1),
    Bin2 = quic_frame:encode({max_streams, uni, 50}),
    {ok, {max_streams, uni, 50}, <<>>} = quic_frame:decode(Bin2),
    ok.

connection_close_frame(_Config) ->
    Bin = quic_frame:encode({connection_close, 0, 0, <<"goodbye">>}),
    {ok, {connection_close, 0, 0, <<"goodbye">>}, <<>>} = quic_frame:decode(Bin),
    ok.

connection_close_app_frame(_Config) ->
    Bin = quic_frame:encode({connection_close_app, 1, <<"app error">>}),
    {ok, {connection_close_app, 1, <<"app error">>}, <<>>} = quic_frame:decode(Bin),
    ok.

handshake_done_frame(_Config) ->
    Bin = quic_frame:encode(handshake_done),
    {ok, handshake_done, <<>>} = quic_frame:decode(Bin),
    ok.

new_connection_id_frame(_Config) ->
    CID = <<1,2,3,4,5,6,7,8>>,
    Token = crypto:strong_rand_bytes(16),
    Bin = quic_frame:encode({new_connection_id, 1, 0, CID, Token}),
    {ok, {new_connection_id, 1, 0, CID, Token}, <<>>} = quic_frame:decode(Bin),
    ok.

path_challenge_response_frames(_Config) ->
    Data = <<1,2,3,4,5,6,7,8>>,
    ChBin = quic_frame:encode({path_challenge, Data}),
    {ok, {path_challenge, Data}, <<>>} = quic_frame:decode(ChBin),
    ReBin = quic_frame:encode({path_response, Data}),
    {ok, {path_response, Data}, <<>>} = quic_frame:decode(ReBin),
    ok.

datagram_frame(_Config) ->
    Data = <<"unreliable data">>,
    Bin = quic_frame:encode({datagram, Data}),
    {ok, {datagram, Data}, <<>>} = quic_frame:decode(Bin),
    ok.

decode_all_frames(_Config) ->
    %% Encode multiple frames and decode them all
    F1 = quic_frame:encode(ping),
    F2 = quic_frame:encode({max_data, 1024}),
    F3 = quic_frame:encode({stream, 0, 0, <<"data">>, true}),
    Combined = <<F1/binary, F2/binary, F3/binary>>,
    {ok, [ping, {max_data, 1024}, {stream, 0, 0, <<"data">>, true}]} =
        quic_frame:decode_all(Combined),
    ok.
