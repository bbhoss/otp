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

-module(quic_varint_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([
    encode_decode_1byte/1,
    encode_decode_2byte/1,
    encode_decode_4byte/1,
    encode_decode_8byte/1,
    rfc_test_vectors/1,
    roundtrip_boundary_values/1,
    encode_len/1
]).

all() ->
    [{group, basic}].

groups() ->
    [{basic, [parallel], [
        encode_decode_1byte,
        encode_decode_2byte,
        encode_decode_4byte,
        encode_decode_8byte,
        rfc_test_vectors,
        roundtrip_boundary_values,
        encode_len
    ]}].

%% RFC 9000 Appendix A.1 - Sample Variable-Length Integer Decodings
rfc_test_vectors(_Config) ->
    %% Example: 0x25 (37) -> 1 byte encoding
    {37, <<>>} = quic_varint:decode(<<16#25>>),
    %% Example: 0x7bbd (15293) -> 2 byte encoding
    {15293, <<>>} = quic_varint:decode(<<16#7b, 16#bd>>),
    %% Example: 0x9d7f3e7d (494878333) -> 4 byte encoding
    {494878333, <<>>} = quic_varint:decode(<<16#9d, 16#7f, 16#3e, 16#7d>>),
    %% Example: 0xc2197c5eff14e88c (151288809941952652) -> 8 byte encoding
    {151288809941952652, <<>>} = quic_varint:decode(
        <<16#c2, 16#19, 16#7c, 16#5e, 16#ff, 16#14, 16#e8, 16#8c>>),
    ok.

encode_decode_1byte(_Config) ->
    lists:foreach(fun(V) ->
        Bin = quic_varint:encode(V),
        1 = byte_size(Bin),
        {V, <<>>} = quic_varint:decode(Bin)
    end, [0, 1, 32, 63]).

encode_decode_2byte(_Config) ->
    lists:foreach(fun(V) ->
        Bin = quic_varint:encode(V),
        2 = byte_size(Bin),
        {V, <<>>} = quic_varint:decode(Bin)
    end, [64, 100, 1000, 16383]).

encode_decode_4byte(_Config) ->
    lists:foreach(fun(V) ->
        Bin = quic_varint:encode(V),
        4 = byte_size(Bin),
        {V, <<>>} = quic_varint:decode(Bin)
    end, [16384, 100000, 1073741823]).

encode_decode_8byte(_Config) ->
    lists:foreach(fun(V) ->
        Bin = quic_varint:encode(V),
        8 = byte_size(Bin),
        {V, <<>>} = quic_varint:decode(Bin)
    end, [1073741824, 4611686018427387903]).

roundtrip_boundary_values(_Config) ->
    Boundaries = [0, 63, 64, 16383, 16384, 1073741823,
                  1073741824, 4611686018427387903],
    lists:foreach(fun(V) ->
        Bin = quic_varint:encode(V),
        {V, <<>>} = quic_varint:decode(Bin)
    end, Boundaries).

encode_len(_Config) ->
    1 = quic_varint:encode_len(0),
    1 = quic_varint:encode_len(63),
    2 = quic_varint:encode_len(64),
    2 = quic_varint:encode_len(16383),
    4 = quic_varint:encode_len(16384),
    4 = quic_varint:encode_len(1073741823),
    8 = quic_varint:encode_len(1073741824),
    ok.
