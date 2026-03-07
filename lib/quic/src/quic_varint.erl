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

%% QUIC Variable-Length Integer Encoding (RFC 9000, Section 16)
%%
%% QUIC uses a variable-length integer encoding with the two most
%% significant bits indicating the length of the encoding:
%%   2MSB=00: 1 byte,  6-bit value (0..63)
%%   2MSB=01: 2 bytes, 14-bit value (0..16383)
%%   2MSB=10: 4 bytes, 30-bit value (0..1073741823)
%%   2MSB=11: 8 bytes, 62-bit value (0..4611686018427387903)

-module(quic_varint).

-export([encode/1, decode/1, encode_len/1]).

-define(MAX_1BYTE, 63).
-define(MAX_2BYTE, 16383).
-define(MAX_4BYTE, 1073741823).
-define(MAX_8BYTE, 4611686018427387903).

%% @doc Encode an integer as a QUIC variable-length integer.
-spec encode(non_neg_integer()) -> binary().
encode(V) when V =< ?MAX_1BYTE ->
    <<0:2, V:6>>;
encode(V) when V =< ?MAX_2BYTE ->
    <<1:2, V:14>>;
encode(V) when V =< ?MAX_4BYTE ->
    <<2:2, V:30>>;
encode(V) when V =< ?MAX_8BYTE ->
    <<3:2, V:62>>.

%% @doc Decode a QUIC variable-length integer from binary.
%% Returns {Value, Rest} where Rest is the remaining binary.
-spec decode(binary()) -> {non_neg_integer(), binary()}.
decode(<<0:2, V:6, Rest/binary>>) ->
    {V, Rest};
decode(<<1:2, V:14, Rest/binary>>) ->
    {V, Rest};
decode(<<2:2, V:30, Rest/binary>>) ->
    {V, Rest};
decode(<<3:2, V:62, Rest/binary>>) ->
    {V, Rest}.

%% @doc Return the encoded byte length of a varint value.
-spec encode_len(non_neg_integer()) -> 1 | 2 | 4 | 8.
encode_len(V) when V =< ?MAX_1BYTE -> 1;
encode_len(V) when V =< ?MAX_2BYTE -> 2;
encode_len(V) when V =< ?MAX_4BYTE -> 4;
encode_len(V) when V =< ?MAX_8BYTE -> 8.
