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

%% QUIC Transport Parameters (RFC 9000, Section 18)
%%
%% Transport parameters are exchanged during the TLS handshake as
%% a TLS extension (type 0x0039). They are encoded as a sequence
%% of (ID, Length, Value) tuples using QUIC variable-length integers.

-module(quic_transport_params).

-include("quic.hrl").

-export([encode/1, decode/1, validate/2, default_client/0, default_server/1]).

%% @doc Encode transport parameters to binary for TLS extension.
-spec encode(#transport_params{}) -> binary().
encode(#transport_params{} = P) ->
    Params = lists:flatten([
        encode_param_cid(?TP_ORIGINAL_DESTINATION_CONNECTION_ID,
                         P#transport_params.original_destination_connection_id),
        encode_param_varint(?TP_MAX_IDLE_TIMEOUT,
                            P#transport_params.max_idle_timeout, 0),
        encode_param_fixed(?TP_STATELESS_RESET_TOKEN,
                           P#transport_params.stateless_reset_token),
        encode_param_varint(?TP_MAX_UDP_PAYLOAD_SIZE,
                            P#transport_params.max_udp_payload_size, 65527),
        encode_param_varint(?TP_INITIAL_MAX_DATA,
                            P#transport_params.initial_max_data, 0),
        encode_param_varint(?TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL,
                            P#transport_params.initial_max_stream_data_bidi_local, 0),
        encode_param_varint(?TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE,
                            P#transport_params.initial_max_stream_data_bidi_remote, 0),
        encode_param_varint(?TP_INITIAL_MAX_STREAM_DATA_UNI,
                            P#transport_params.initial_max_stream_data_uni, 0),
        encode_param_varint(?TP_INITIAL_MAX_STREAMS_BIDI,
                            P#transport_params.initial_max_streams_bidi, 0),
        encode_param_varint(?TP_INITIAL_MAX_STREAMS_UNI,
                            P#transport_params.initial_max_streams_uni, 0),
        encode_param_varint(?TP_ACK_DELAY_EXPONENT,
                            P#transport_params.ack_delay_exponent,
                            ?DEFAULT_ACK_DELAY_EXPONENT),
        encode_param_varint(?TP_MAX_ACK_DELAY,
                            P#transport_params.max_ack_delay,
                            ?DEFAULT_MAX_ACK_DELAY),
        encode_param_flag(?TP_DISABLE_ACTIVE_MIGRATION,
                          P#transport_params.disable_active_migration),
        encode_param_varint(?TP_ACTIVE_CONNECTION_ID_LIMIT,
                            P#transport_params.active_connection_id_limit,
                            ?DEFAULT_ACTIVE_CONNECTION_ID_LIMIT),
        encode_param_cid(?TP_INITIAL_SOURCE_CONNECTION_ID,
                         P#transport_params.initial_source_connection_id),
        encode_param_cid(?TP_RETRY_SOURCE_CONNECTION_ID,
                         P#transport_params.retry_source_connection_id),
        encode_param_varint(?TP_MAX_DATAGRAM_FRAME_SIZE,
                            P#transport_params.max_datagram_frame_size, 0),
        encode_param_flag(?TP_GREASE_QUIC_BIT,
                          P#transport_params.grease_quic_bit)
    ]),
    iolist_to_binary(Params).

%% @doc Decode transport parameters from binary.
-spec decode(binary()) -> {ok, #transport_params{}} | {error, term()}.
decode(Bin) ->
    try
        {ok, decode_params(Bin, #transport_params{})}
    catch
        error:Reason -> {error, Reason}
    end.

%% @doc Default transport parameters for a client.
-spec default_client() -> #transport_params{}.
default_client() ->
    #transport_params{
        initial_max_data = 1048576,           %% 1MB
        initial_max_stream_data_bidi_local = 65536,
        initial_max_stream_data_bidi_remote = 65536,
        initial_max_stream_data_uni = 65536,
        initial_max_streams_bidi = 100,
        initial_max_streams_uni = 100,
        max_idle_timeout = 30000,             %% 30 seconds
        active_connection_id_limit = 8,
        max_datagram_frame_size = 65535,
        grease_quic_bit = true
    }.

%% @doc Default transport parameters for a server.
-spec default_server(binary()) -> #transport_params{}.
default_server(OriginalDCID) ->
    #transport_params{
        original_destination_connection_id = OriginalDCID,
        initial_max_data = 1048576,
        initial_max_stream_data_bidi_local = 65536,
        initial_max_stream_data_bidi_remote = 65536,
        initial_max_stream_data_uni = 65536,
        initial_max_streams_bidi = 100,
        initial_max_streams_uni = 100,
        max_idle_timeout = 30000,
        active_connection_id_limit = 8,
        max_datagram_frame_size = 65535,
        grease_quic_bit = true
    }.

%% ===================================================================
%% Internal - Encoding
%% ===================================================================

encode_param_varint(Id, Value, Default) when Value =:= Default -> [];
encode_param_varint(Id, Value, _Default) ->
    ValBin = quic_varint:encode(Value),
    [quic_varint:encode(Id),
     quic_varint:encode(byte_size(ValBin)),
     ValBin].

encode_param_cid(_Id, undefined) -> [];
encode_param_cid(Id, CID) when is_binary(CID) ->
    [quic_varint:encode(Id),
     quic_varint:encode(byte_size(CID)),
     CID].

encode_param_fixed(_Id, undefined) -> [];
encode_param_fixed(Id, Value) when is_binary(Value) ->
    [quic_varint:encode(Id),
     quic_varint:encode(byte_size(Value)),
     Value].

encode_param_flag(_Id, false) -> [];
encode_param_flag(Id, true) ->
    [quic_varint:encode(Id),
     quic_varint:encode(0)].

%% ===================================================================
%% Internal - Decoding
%% ===================================================================

decode_params(<<>>, Params) -> Params;
decode_params(Bin, Params) ->
    {Id, R1} = quic_varint:decode(Bin),
    {Len, R2} = quic_varint:decode(R1),
    <<Value:Len/binary, Rest/binary>> = R2,
    NewParams = set_param(Id, Value, Params),
    decode_params(Rest, NewParams).

set_param(?TP_ORIGINAL_DESTINATION_CONNECTION_ID, V, P) ->
    P#transport_params{original_destination_connection_id = V};
set_param(?TP_MAX_IDLE_TIMEOUT, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{max_idle_timeout = Val};
set_param(?TP_STATELESS_RESET_TOKEN, V, P) ->
    P#transport_params{stateless_reset_token = V};
set_param(?TP_MAX_UDP_PAYLOAD_SIZE, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{max_udp_payload_size = Val};
set_param(?TP_INITIAL_MAX_DATA, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{initial_max_data = Val};
set_param(?TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{initial_max_stream_data_bidi_local = Val};
set_param(?TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{initial_max_stream_data_bidi_remote = Val};
set_param(?TP_INITIAL_MAX_STREAM_DATA_UNI, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{initial_max_stream_data_uni = Val};
set_param(?TP_INITIAL_MAX_STREAMS_BIDI, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{initial_max_streams_bidi = Val};
set_param(?TP_INITIAL_MAX_STREAMS_UNI, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{initial_max_streams_uni = Val};
set_param(?TP_ACK_DELAY_EXPONENT, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{ack_delay_exponent = Val};
set_param(?TP_MAX_ACK_DELAY, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{max_ack_delay = Val};
set_param(?TP_DISABLE_ACTIVE_MIGRATION, <<>>, P) ->
    P#transport_params{disable_active_migration = true};
set_param(?TP_ACTIVE_CONNECTION_ID_LIMIT, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{active_connection_id_limit = Val};
set_param(?TP_INITIAL_SOURCE_CONNECTION_ID, V, P) ->
    P#transport_params{initial_source_connection_id = V};
set_param(?TP_RETRY_SOURCE_CONNECTION_ID, V, P) ->
    P#transport_params{retry_source_connection_id = V};
set_param(?TP_MAX_DATAGRAM_FRAME_SIZE, V, P) ->
    {Val, <<>>} = quic_varint:decode(V),
    P#transport_params{max_datagram_frame_size = Val};
set_param(?TP_GREASE_QUIC_BIT, <<>>, P) ->
    P#transport_params{grease_quic_bit = true};
set_param(_Unknown, _V, P) ->
    %% Unknown parameters MUST be ignored (RFC 9000, Section 18)
    P.

%% @doc Validate remote transport parameters (RFC 9000 §18).
%% PeerRole is the role of the peer (client or server).
-spec validate(#transport_params{}, client | server) -> ok | {error, term()}.
validate(#transport_params{} = P, PeerRole) ->
    Checks = [
        %% RFC 9000 §18.2: max_streams MUST NOT exceed 2^60
        {P#transport_params.initial_max_streams_bidi =< (1 bsl 60),
         {transport_parameter_error, max_streams_too_large}},
        {P#transport_params.initial_max_streams_uni =< (1 bsl 60),
         {transport_parameter_error, max_streams_too_large}},
        %% RFC 9000 §18.2: ack_delay_exponent MUST NOT exceed 20
        {P#transport_params.ack_delay_exponent =< 20,
         {transport_parameter_error, ack_delay_exponent_too_large}},
        %% RFC 9000 §18.2: max_ack_delay MUST be less than 2^14
        {P#transport_params.max_ack_delay < (1 bsl 14),
         {transport_parameter_error, max_ack_delay_too_large}},
        %% RFC 9000 §18.2: active_connection_id_limit MUST be at least 2
        {P#transport_params.active_connection_id_limit >= 2,
         {transport_parameter_error, active_cid_limit_too_small}},
        %% RFC 9000 §18.2: Clients MUST NOT send original_destination_connection_id
        {not (PeerRole =:= client andalso
              P#transport_params.original_destination_connection_id =/= undefined),
         {transport_parameter_error, client_sent_odcid}},
        %% RFC 9000 §18.2: Clients MUST NOT send stateless_reset_token
        {not (PeerRole =:= client andalso
              P#transport_params.stateless_reset_token =/= undefined),
         {transport_parameter_error, client_sent_stateless_reset_token}}
    ],
    case lists:dropwhile(fun({true, _}) -> true; (_) -> false end, Checks) of
        [] -> ok;
        [{false, Error} | _] -> {error, Error}
    end.
