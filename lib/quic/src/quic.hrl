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

-ifndef(QUIC_HRL).
-define(QUIC_HRL, true).

%% ===================================================================
%% QUIC Versions (RFC 9000, RFC 9369)
%% ===================================================================

-define(QUIC_V1, 16#00000001).
-define(QUIC_V2, 16#6b3343cf).

%% ===================================================================
%% Long Header Packet Types (RFC 9000, Section 17.2)
%% ===================================================================

%% QUIC v1 packet type field values (2-bit field in long header)
-define(INITIAL_PACKET, 16#00).
-define(ZERO_RTT_PACKET, 16#01).
-define(HANDSHAKE_PACKET, 16#02).
-define(RETRY_PACKET, 16#03).

%% QUIC v2 swaps these (RFC 9369, Section 3.2)
-define(INITIAL_PACKET_V2, 16#01).
-define(ZERO_RTT_PACKET_V2, 16#02).
-define(HANDSHAKE_PACKET_V2, 16#03).
-define(RETRY_PACKET_V2, 16#00).

%% ===================================================================
%% Frame Types (RFC 9000, Section 19)
%% ===================================================================

-define(FRAME_PADDING, 16#00).
-define(FRAME_PING, 16#01).
-define(FRAME_ACK, 16#02).
-define(FRAME_ACK_ECN, 16#03).
-define(FRAME_RESET_STREAM, 16#04).
-define(FRAME_STOP_SENDING, 16#05).
-define(FRAME_CRYPTO, 16#06).
-define(FRAME_NEW_TOKEN, 16#07).
-define(FRAME_STREAM, 16#08).       %% 0x08-0x0f (low 3 bits are flags)
-define(FRAME_STREAM_END, 16#0f).
-define(FRAME_MAX_DATA, 16#10).
-define(FRAME_MAX_STREAM_DATA, 16#11).
-define(FRAME_MAX_STREAMS_BIDI, 16#12).
-define(FRAME_MAX_STREAMS_UNI, 16#13).
-define(FRAME_DATA_BLOCKED, 16#14).
-define(FRAME_STREAM_DATA_BLOCKED, 16#15).
-define(FRAME_STREAMS_BLOCKED_BIDI, 16#16).
-define(FRAME_STREAMS_BLOCKED_UNI, 16#17).
-define(FRAME_NEW_CONNECTION_ID, 16#18).
-define(FRAME_RETIRE_CONNECTION_ID, 16#19).
-define(FRAME_PATH_CHALLENGE, 16#1a).
-define(FRAME_PATH_RESPONSE, 16#1b).
-define(FRAME_CONNECTION_CLOSE, 16#1c).
-define(FRAME_CONNECTION_CLOSE_APP, 16#1d).
-define(FRAME_HANDSHAKE_DONE, 16#1e).

%% RFC 9221 - Unreliable Datagrams
-define(FRAME_DATAGRAM, 16#30).
-define(FRAME_DATAGRAM_LEN, 16#31).

%% STREAM frame flag bits (lowest 3 bits of frame type 0x08-0x0f)
-define(STREAM_FIN_BIT, 16#01).
-define(STREAM_LEN_BIT, 16#02).
-define(STREAM_OFF_BIT, 16#04).

%% ===================================================================
%% Transport Error Codes (RFC 9000, Section 20.1)
%% ===================================================================

-define(QUIC_NO_ERROR, 16#00).
-define(QUIC_INTERNAL_ERROR, 16#01).
-define(QUIC_CONNECTION_REFUSED, 16#02).
-define(QUIC_FLOW_CONTROL_ERROR, 16#03).
-define(QUIC_STREAM_LIMIT_ERROR, 16#04).
-define(QUIC_STREAM_STATE_ERROR, 16#05).
-define(QUIC_FINAL_SIZE_ERROR, 16#06).
-define(QUIC_FRAME_ENCODING_ERROR, 16#07).
-define(QUIC_TRANSPORT_PARAMETER_ERROR, 16#08).
-define(QUIC_CONNECTION_ID_LIMIT_ERROR, 16#09).
-define(QUIC_PROTOCOL_VIOLATION, 16#0a).
-define(QUIC_INVALID_TOKEN, 16#0b).
-define(QUIC_APPLICATION_ERROR, 16#0c).
-define(QUIC_CRYPTO_BUFFER_EXCEEDED, 16#0d).
-define(QUIC_KEY_UPDATE_ERROR, 16#0e).
-define(QUIC_AEAD_LIMIT_REACHED, 16#0f).
-define(QUIC_NO_VIABLE_PATH, 16#10).
-define(QUIC_CRYPTO_ERROR_BASE, 16#0100). %% 0x0100-0x01ff

%% ===================================================================
%% Transport Parameters (RFC 9000, Section 18.2)
%% ===================================================================

-define(TP_ORIGINAL_DESTINATION_CONNECTION_ID, 16#00).
-define(TP_MAX_IDLE_TIMEOUT, 16#01).
-define(TP_STATELESS_RESET_TOKEN, 16#02).
-define(TP_MAX_UDP_PAYLOAD_SIZE, 16#03).
-define(TP_INITIAL_MAX_DATA, 16#04).
-define(TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, 16#05).
-define(TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, 16#06).
-define(TP_INITIAL_MAX_STREAM_DATA_UNI, 16#07).
-define(TP_INITIAL_MAX_STREAMS_BIDI, 16#08).
-define(TP_INITIAL_MAX_STREAMS_UNI, 16#09).
-define(TP_ACK_DELAY_EXPONENT, 16#0a).
-define(TP_MAX_ACK_DELAY, 16#0b).
-define(TP_DISABLE_ACTIVE_MIGRATION, 16#0c).
-define(TP_PREFERRED_ADDRESS, 16#0d).
-define(TP_ACTIVE_CONNECTION_ID_LIMIT, 16#0e).
-define(TP_INITIAL_SOURCE_CONNECTION_ID, 16#0f).
-define(TP_RETRY_SOURCE_CONNECTION_ID, 16#10).

%% RFC 9221
-define(TP_MAX_DATAGRAM_FRAME_SIZE, 16#0020).

%% RFC 9287 - Greasing the QUIC Bit
-define(TP_GREASE_QUIC_BIT, 16#2ab2).

%% ===================================================================
%% TLS Constants for QUIC
%% ===================================================================

%% QUIC transport parameters TLS extension type (RFC 9001, Section 8.2)
-define(TLS_EXT_QUIC_TRANSPORT_PARAMS, 16#0039).

%% TLS 1.3 handshake message types
-define(TLS_CLIENT_HELLO, 1).
-define(TLS_SERVER_HELLO, 2).
-define(TLS_NEW_SESSION_TICKET, 4).
-define(TLS_ENCRYPTED_EXTENSIONS, 8).
-define(TLS_CERTIFICATE, 11).
-define(TLS_CERTIFICATE_REQUEST, 13).
-define(TLS_CERTIFICATE_VERIFY, 15).
-define(TLS_FINISHED, 20).
-define(TLS_KEY_UPDATE, 24).

%% TLS cipher suites
-define(TLS_AES_128_GCM_SHA256, <<16#13, 16#01>>).
-define(TLS_AES_256_GCM_SHA384, <<16#13, 16#02>>).
-define(TLS_CHACHA20_POLY1305_SHA256, <<16#13, 16#03>>).

%% TLS named groups
-define(TLS_X25519, 16#001d).
-define(TLS_SECP256R1, 16#0017).

%% TLS signature algorithms
-define(TLS_ECDSA_SECP256R1_SHA256, 16#0403).
-define(TLS_RSA_PSS_RSAE_SHA256, 16#0804).
-define(TLS_ED25519, 16#0807).

%% TLS extension types
-define(TLS_EXT_SERVER_NAME, 0).
-define(TLS_EXT_SUPPORTED_GROUPS, 10).
-define(TLS_EXT_SIGNATURE_ALGORITHMS, 13).
-define(TLS_EXT_ALPN, 16).
-define(TLS_EXT_SUPPORTED_VERSIONS, 43).
-define(TLS_EXT_KEY_SHARE, 51).

%% TLS record content type
-define(TLS_HANDSHAKE, 22).

%% TLS versions
-define(TLS_1_2, <<16#03, 16#03>>).
-define(TLS_1_3, <<16#03, 16#04>>).

%% ===================================================================
%% Crypto Constants (RFC 9001)
%% ===================================================================

%% QUIC v1 initial salt (RFC 9001, Section 5.2)
-define(QUIC_V1_INITIAL_SALT,
        <<16#38, 16#76, 16#2c, 16#f7, 16#f5, 16#59, 16#34, 16#b3,
          16#4d, 16#17, 16#9a, 16#e6, 16#a4, 16#c8, 16#0c, 16#ad,
          16#cc, 16#bb, 16#7f, 16#0a>>).

%% QUIC v2 initial salt (RFC 9369, Section 3.3.1)
-define(QUIC_V2_INITIAL_SALT,
        <<16#0d, 16#de, 16#c3, 16#b1, 16#8c, 16#e1, 16#d0, 16#45,
          16#97, 16#cd, 16#be, 16#d1, 16#c3, 16#9b, 16#94, 16#72,
          16#b0, 16#7c, 16#7b, 16#a4>>).

%% QUIC label prefixes for HKDF-Expand-Label
%% HKDF-Expand-Label always uses "tls13 " prefix (per TLS 1.3 RFC 8446)
%% QUIC key separation is achieved through label names, not prefix changes
-define(TLS13_LABEL_PREFIX, <<"tls13 ">>).
%% QUIC v1 key labels (RFC 9001)
-define(QUIC_V1_KEY_LABEL, <<"quic key">>).
-define(QUIC_V1_IV_LABEL, <<"quic iv">>).
-define(QUIC_V1_HP_LABEL, <<"quic hp">>).
-define(QUIC_V1_KU_LABEL, <<"quic ku">>).
%% QUIC v2 key labels (RFC 9369)
-define(QUIC_V2_KEY_LABEL, <<"quicv2 key">>).
-define(QUIC_V2_IV_LABEL, <<"quicv2 iv">>).
-define(QUIC_V2_HP_LABEL, <<"quicv2 hp">>).
-define(QUIC_V2_KU_LABEL, <<"quicv2 ku">>).

%% ===================================================================
%% Defaults
%% ===================================================================

-define(DEFAULT_MAX_UDP_PAYLOAD_SIZE, 1200).
-define(DEFAULT_ACK_DELAY_EXPONENT, 3).
-define(DEFAULT_MAX_ACK_DELAY, 25).    %% milliseconds
-define(DEFAULT_ACTIVE_CONNECTION_ID_LIMIT, 2).

%% Initial congestion window (RFC 9002, Section 7.2)
-define(INITIAL_WINDOW_PACKETS, 10).
-define(MINIMUM_WINDOW_PACKETS, 2).
-define(LOSS_REDUCTION_FACTOR, 0.5).

%% Packet number space indices
-define(PN_SPACE_INITIAL, initial).
-define(PN_SPACE_HANDSHAKE, handshake).
-define(PN_SPACE_APPLICATION, application).

%% ===================================================================
%% Records
%% ===================================================================

-record(quic_packet, {
    type            :: initial | handshake | zero_rtt | one_rtt
                     | retry | version_negotiation,
    version         :: non_neg_integer() | undefined,
    dcid            :: binary(),
    scid = <<>>     :: binary(),
    packet_number   :: non_neg_integer() | undefined,
    token = <<>>    :: binary(),
    payload = <<>>  :: binary() | [tuple()],
    raw_header = <<>> :: binary()
}).

-record(quic_stream, {
    id              :: non_neg_integer(),
    send_state = ready :: ready | send | data_sent | reset_sent | reset_recvd,
    recv_state = recv  :: recv | size_known | data_recvd | data_read | reset_recvd,
    send_buffer = <<>> :: binary(),
    recv_buffer = #{}  :: #{non_neg_integer() => binary()}, %% offset => data
    send_offset = 0    :: non_neg_integer(),
    recv_offset = 0    :: non_neg_integer(),
    final_size         :: non_neg_integer() | undefined,
    max_send_data = 0  :: non_neg_integer(),
    max_recv_data = 0  :: non_neg_integer(),
    recv_data_size = 0 :: non_neg_integer(),
    fin_sent = false   :: boolean(),
    fin_received = false :: boolean(),
    recv_waiters = []  :: list()
}).

-record(pn_space, {
    next_pn = 0            :: non_neg_integer(),
    largest_received = -1  :: integer(),
    largest_acked = -1     :: integer(),
    ack_eliciting_in_flight = 0 :: non_neg_integer(),
    received_pns = []      :: list(),   %% sorted list of received PNs
    sent_packets = #{}     :: #{non_neg_integer() => map()},
    crypto_offset = 0      :: non_neg_integer(),
    crypto_buffer = <<>>   :: binary()
}).

-record(recovery, {
    smoothed_rtt = 333     :: number(), %% milliseconds, initial 333ms
    rttvar = 166           :: number(), %% milliseconds, initial 166ms
    min_rtt = infinity     :: number() | infinity,
    latest_rtt = 0         :: number(),
    max_ack_delay = 25     :: non_neg_integer(),
    loss_time = #{         %% per PN space
        initial => undefined,
        handshake => undefined,
        application => undefined
    } :: map(),
    congestion_window      :: non_neg_integer(),
    bytes_in_flight = 0    :: non_neg_integer(),
    ssthresh = infinity    :: non_neg_integer() | infinity,
    congestion_recovery_start_time :: integer() | undefined,
    pto_count = 0          :: non_neg_integer(),
    max_datagram_size = ?DEFAULT_MAX_UDP_PAYLOAD_SIZE :: non_neg_integer()
}).

-record(transport_params, {
    original_destination_connection_id :: binary() | undefined,
    max_idle_timeout = 0                :: non_neg_integer(),
    stateless_reset_token               :: binary() | undefined,
    max_udp_payload_size = 65527        :: non_neg_integer(),
    initial_max_data = 0                :: non_neg_integer(),
    initial_max_stream_data_bidi_local = 0 :: non_neg_integer(),
    initial_max_stream_data_bidi_remote = 0 :: non_neg_integer(),
    initial_max_stream_data_uni = 0     :: non_neg_integer(),
    initial_max_streams_bidi = 0        :: non_neg_integer(),
    initial_max_streams_uni = 0         :: non_neg_integer(),
    ack_delay_exponent = ?DEFAULT_ACK_DELAY_EXPONENT :: non_neg_integer(),
    max_ack_delay = ?DEFAULT_MAX_ACK_DELAY :: non_neg_integer(),
    disable_active_migration = false    :: boolean(),
    active_connection_id_limit = ?DEFAULT_ACTIVE_CONNECTION_ID_LIMIT :: non_neg_integer(),
    initial_source_connection_id        :: binary() | undefined,
    retry_source_connection_id          :: binary() | undefined,
    max_datagram_frame_size = 0         :: non_neg_integer(),
    grease_quic_bit = false             :: boolean()
}).

-endif. %% QUIC_HRL
