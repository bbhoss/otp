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

-module(quic_crypto_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("../src/quic.hrl").

-export([all/0, groups/0]).
-export([
    initial_key_derivation_v1/1,
    aead_encrypt_decrypt/1,
    make_nonce/1,
    hkdf_expand_label/1,
    initial_salt/1
]).

all() ->
    [{group, crypto_tests}].

groups() ->
    [{crypto_tests, [parallel], [
        initial_key_derivation_v1,
        aead_encrypt_decrypt,
        make_nonce,
        hkdf_expand_label,
        initial_salt
    ]}].

%% RFC 9001 Appendix A - Initial Key Derivation Test Vectors
%% Client Destination Connection ID: 0x8394c8f03e515708
initial_key_derivation_v1(_Config) ->
    DCID = <<16#83, 16#94, 16#c8, 16#f0, 16#3e, 16#51, 16#57, 16#08>>,
    #{client := {ClientKey, ClientIV, ClientHP},
      server := {ServerKey, ServerIV, ServerHP}} =
        quic_crypto:derive_initial_keys(DCID),

    %% RFC 9001 Appendix A.1:
    %% client_initial_secret:
    %%   c00cf151ca5be075ed0ebfb5c80323c4 2d6b7db67881289af4008f1f6c357aea

    %% client key: 1f369613dd76d5467730efcbe3b1a22d
    ct:log("Client Key: ~s", [bin_to_hex(ClientKey)]),
    ExpClientKey = hex_to_bin("1f369613dd76d5467730efcbe3b1a22d"),
    ExpClientKey = ClientKey,

    %% client iv: fa044b2f42a3fd3b46fb255c
    ct:log("Client IV: ~s", [bin_to_hex(ClientIV)]),
    ExpClientIV = hex_to_bin("fa044b2f42a3fd3b46fb255c"),
    ExpClientIV = ClientIV,

    %% client hp: 9f50449e04a0e810283a1e9933adedd2
    ct:log("Client HP: ~s", [bin_to_hex(ClientHP)]),
    ExpClientHP = hex_to_bin("9f50449e04a0e810283a1e9933adedd2"),
    ExpClientHP = ClientHP,

    %% server key: cf3a5331653c364c88f0f379b6067e37
    ct:log("Server Key: ~s", [bin_to_hex(ServerKey)]),
    ExpServerKey = hex_to_bin("cf3a5331653c364c88f0f379b6067e37"),
    ExpServerKey = ServerKey,

    %% server iv: 0ac1493ca1905853b0bba03e
    ct:log("Server IV: ~s", [bin_to_hex(ServerIV)]),
    ExpServerIV = hex_to_bin("0ac1493ca1905853b0bba03e"),
    ExpServerIV = ServerIV,

    %% server hp: c206b8d9b9f0f37644430b490eeaa314
    ct:log("Server HP: ~s", [bin_to_hex(ServerHP)]),
    ExpServerHP = hex_to_bin("c206b8d9b9f0f37644430b490eeaa314"),
    ExpServerHP = ServerHP,

    ok.

aead_encrypt_decrypt(_Config) ->
    Key = crypto:strong_rand_bytes(16),
    IV = crypto:strong_rand_bytes(12),
    PN = 42,
    AAD = <<"header data">>,
    PlainText = <<"Hello, QUIC AEAD!">>,

    CipherText = quic_crypto:encrypt_payload(PlainText, Key, IV, PN, AAD),
    true = byte_size(CipherText) =:= byte_size(PlainText) + 16, %% 16 byte tag

    {ok, PlainText} = quic_crypto:decrypt_payload(CipherText, Key, IV, PN, AAD),

    %% Wrong key should fail
    WrongKey = crypto:strong_rand_bytes(16),
    {error, decrypt_failed} = quic_crypto:decrypt_payload(CipherText, WrongKey, IV, PN, AAD),
    ok.

make_nonce(_Config) ->
    IV = <<1,2,3,4,5,6,7,8,9,10,11,12>>,
    Nonce = quic_crypto:make_nonce(IV, 0),
    IV = Nonce, %% XOR with 0 should be identity
    %% XOR with 1
    Nonce1 = quic_crypto:make_nonce(IV, 1),
    <<1,2,3,4,5,6,7,8,9,10,11,13>> = Nonce1,
    ok.

hkdf_expand_label(_Config) ->
    Secret = crypto:strong_rand_bytes(32),
    Label = <<"key">>,
    Context = <<>>,
    %% Should produce consistent output
    Result1 = quic_crypto:hkdf_expand_label(Secret, Label, Context, 16),
    Result2 = quic_crypto:hkdf_expand_label(Secret, Label, Context, 16),
    Result1 = Result2,
    16 = byte_size(Result1),
    ok.

initial_salt(_Config) ->
    V1Salt = quic_crypto:initial_salt(?QUIC_V1),
    20 = byte_size(V1Salt),
    V2Salt = quic_crypto:initial_salt(?QUIC_V2),
    20 = byte_size(V2Salt),
    true = V1Salt =/= V2Salt,
    ok.

%% Helpers
hex_to_bin(Hex) ->
    << <<(list_to_integer([H], 16)):4>> || H <- Hex >>.

bin_to_hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
