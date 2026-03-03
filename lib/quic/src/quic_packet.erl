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

%% QUIC Packet Encoding/Decoding (RFC 9000, Section 17)
%%
%% QUIC packets have two header formats:
%%   - Long Header: Used for Initial, Handshake, 0-RTT, Retry
%%   - Short Header: Used for 1-RTT (application data)
%%
%% The first bit distinguishes: 1=Long Header, 0=Short Header
%% The second bit is the Fixed Bit (1 normally, RFC 9287 greasing)

-module(quic_packet).

-include("quic.hrl").

-export([
    encode_initial/5,
    encode_handshake/4,
    encode_short/3,
    encode_zero_rtt/4,
    encode_retry/4,
    encode_version_negotiation/3,
    decode_header/1,
    decode_header/2,
    encode_packet_number/2,
    decode_packet_number/3,
    packet_number_length/1,
    pad_initial/2
]).

%% ===================================================================
%% Encoding
%% ===================================================================

%% @doc Encode an Initial packet (before encryption).
%% Returns the raw packet with unprotected header + plaintext payload.
-spec encode_initial(binary(), binary(), binary(), non_neg_integer(), binary()) -> binary().
encode_initial(DCID, SCID, Token, PacketNumber, Payload) ->
    encode_long(?INITIAL_PACKET, ?QUIC_V1, DCID, SCID, PacketNumber,
                Payload, Token).

%% @doc Encode a Handshake packet.
-spec encode_handshake(binary(), binary(), non_neg_integer(), binary()) -> binary().
encode_handshake(DCID, SCID, PacketNumber, Payload) ->
    encode_long(?HANDSHAKE_PACKET, ?QUIC_V1, DCID, SCID, PacketNumber,
                Payload, <<>>).

%% @doc Encode a 0-RTT packet.
-spec encode_zero_rtt(binary(), binary(), non_neg_integer(), binary()) -> binary().
encode_zero_rtt(DCID, SCID, PacketNumber, Payload) ->
    encode_long(?ZERO_RTT_PACKET, ?QUIC_V1, DCID, SCID, PacketNumber,
                Payload, <<>>).

%% @doc Encode a Short Header (1-RTT) packet.
-spec encode_short(binary(), non_neg_integer(), binary()) -> binary().
encode_short(DCID, PacketNumber, Payload) ->
    PNLen = packet_number_length(PacketNumber),
    PNBin = encode_pn_bytes(PacketNumber, PNLen),
    %% Short header: Form=0, Fixed=1, SpinBit=0, Reserved=00, KeyPhase=0, PNLen
    FirstByte = 16#40 bor (PNLen - 1),
    Header = <<FirstByte:8, DCID/binary, PNBin/binary>>,
    <<Header/binary, Payload/binary>>.

%% @doc Encode a Retry packet (no packet number, no encryption).
-spec encode_retry(binary(), binary(), binary(), binary()) -> binary().
encode_retry(DCID, SCID, Token, RetryIntegrityTag) ->
    DCIDLen = byte_size(DCID),
    SCIDLen = byte_size(SCID),
    %% First byte: Form=1, Fixed=1, Long Packet Type=11 (Retry), unused=0000
    FirstByte = 16#f0,
    <<FirstByte:8, ?QUIC_V1:32,
      DCIDLen:8, DCID/binary,
      SCIDLen:8, SCID/binary,
      Token/binary,
      RetryIntegrityTag:16/binary>>.

%% @doc Encode a Version Negotiation packet.
-spec encode_version_negotiation(binary(), binary(), [non_neg_integer()]) -> binary().
encode_version_negotiation(DCID, SCID, Versions) ->
    DCIDLen = byte_size(DCID),
    SCIDLen = byte_size(SCID),
    VersionsBin = << <<V:32>> || V <- Versions >>,
    %% First byte: Form=1, rest random (we use 0)
    <<16#80:8, 0:32,  %% Version = 0 means Version Negotiation
      DCIDLen:8, DCID/binary,
      SCIDLen:8, SCID/binary,
      VersionsBin/binary>>.

%% @doc Pad an Initial packet to at least MinSize bytes.
%% Initial packets must be at least 1200 bytes (RFC 9000, Section 14.1).
-spec pad_initial(binary(), non_neg_integer()) -> binary().
pad_initial(Packet, MinSize) ->
    PadLen = max(0, MinSize - byte_size(Packet)),
    <<Packet/binary, 0:(PadLen * 8)>>.

%% ===================================================================
%% Decoding
%% ===================================================================

%% @doc Decode a packet header from binary.
%% For short headers, DCIDLen must be known from the connection context.
-spec decode_header(binary()) -> {ok, #quic_packet{}, binary()} | {error, term()}.
decode_header(Bin) ->
    decode_header(Bin, 0).

-spec decode_header(binary(), non_neg_integer()) -> {ok, #quic_packet{}, binary()} | {error, term()}.

%% Long Header (first bit = 1)
decode_header(<<1:1, _FixedBit:1, Type:2, _Reserved:4,
                Version:32,
                DCIDLen:8, DCID:DCIDLen/binary,
                SCIDLen:8, SCID:SCIDLen/binary,
                Rest/binary>> = _Bin, _DCIDLen) when Version =:= 0 ->
    %% Version Negotiation
    Versions = decode_versions(Rest),
    Pkt = #quic_packet{
        type = version_negotiation,
        version = 0,
        dcid = DCID,
        scid = SCID,
        payload = Versions
    },
    {ok, Pkt, <<>>};

decode_header(<<1:1, _FixedBit:1, Type:2, _Reserved:4,
                Version:32,
                DCIDLen:8, DCID:DCIDLen/binary,
                SCIDLen:8, SCID:SCIDLen/binary,
                Rest/binary>> = Bin, _ShortDCIDLen) ->
    PktType = long_packet_type(Type, Version),
    case PktType of
        retry ->
            %% Retry has no packet number, rest is Token + 16-byte integrity tag
            TokenLen = byte_size(Rest) - 16,
            <<Token:TokenLen/binary, IntegrityTag:16/binary>> = Rest,
            Pkt = #quic_packet{
                type = retry,
                version = Version,
                dcid = DCID,
                scid = SCID,
                token = Token,
                payload = IntegrityTag
            },
            {ok, Pkt, <<>>};
        initial ->
            %% Initial has Token Length + Token before length + PN
            {TokenLen, R1} = quic_varint:decode(Rest),
            <<Token:TokenLen/binary, R2/binary>> = R1,
            decode_long_pn(Bin, PktType, Version, DCID, SCID, Token, R2);
        _ ->
            decode_long_pn(Bin, PktType, Version, DCID, SCID, <<>>, Rest)
    end;

%% Short Header (first bit = 0)
decode_header(<<0:1, 1:1, _SpinBit:1, _Reserved:2, _KeyPhase:1, PNLenField:2,
                Rest/binary>> = Bin, DCIDLen) ->
    PNLen = PNLenField + 1,
    <<DCID:DCIDLen/binary, PNBin:PNLen/binary, Payload/binary>> = Rest,
    PacketNumber = decode_pn_bytes(PNBin, PNLen),
    %% Raw header = everything before payload
    HeaderLen = 1 + DCIDLen + PNLen,
    <<RawHeader:HeaderLen/binary, _/binary>> = Bin,
    Pkt = #quic_packet{
        type = one_rtt,
        dcid = DCID,
        packet_number = PacketNumber,
        payload = Payload,
        raw_header = RawHeader
    },
    {ok, Pkt, <<>>};

decode_header(_, _) ->
    {error, invalid_packet}.

%% ===================================================================
%% Packet Number Encoding (RFC 9000, Section 17.1)
%% ===================================================================

%% @doc Encode a packet number with truncation based on largest acknowledged.
%% Returns {TruncatedValue, Length}.
-spec encode_packet_number(non_neg_integer(), integer()) ->
    {non_neg_integer(), 1 | 2 | 3 | 4}.
encode_packet_number(FullPN, LargestAcked) ->
    %% Number of contiguous unacknowledged packet numbers
    NumUnacked = FullPN - LargestAcked,
    %% Minimum length needed: enough bits for twice the range
    MinBits = if
        NumUnacked =< 16#7F -> 8;
        NumUnacked =< 16#7FFF -> 16;
        NumUnacked =< 16#7FFFFF -> 24;
        true -> 32
    end,
    PNLen = MinBits div 8,
    Mask = (1 bsl MinBits) - 1,
    TruncatedPN = FullPN band Mask,
    {TruncatedPN, PNLen}.

%% @doc Decode a truncated packet number to a full packet number.
%% Uses the expected packet number (largest_pn + 1) for reconstruction.
-spec decode_packet_number(non_neg_integer(), 1 | 2 | 3 | 4, integer()) ->
    non_neg_integer().
decode_packet_number(TruncatedPN, PNLen, LargestPN) ->
    ExpectedPN = LargestPN + 1,
    PNNBits = PNLen * 8,
    PNWin = 1 bsl PNNBits,
    PNHWin = PNWin div 2,
    PNMask = PNWin - 1,
    %% The candidate packet number
    CandidatePN = (ExpectedPN band (bnot PNMask)) bor TruncatedPN,
    if
        CandidatePN =< ExpectedPN - PNHWin, CandidatePN + PNWin =< (1 bsl 62) - 1 ->
            CandidatePN + PNWin;
        CandidatePN > ExpectedPN + PNHWin, CandidatePN >= PNWin ->
            CandidatePN - PNWin;
        true ->
            CandidatePN
    end.

%% @doc Return the byte length needed to encode a packet number.
-spec packet_number_length(non_neg_integer()) -> 1 | 2 | 3 | 4.
packet_number_length(PN) when PN =< 16#FF -> 1;
packet_number_length(PN) when PN =< 16#FFFF -> 2;
packet_number_length(PN) when PN =< 16#FFFFFF -> 3;
packet_number_length(_PN) -> 4.

%% ===================================================================
%% Internal
%% ===================================================================

encode_long(Type, Version, DCID, SCID, PacketNumber, Payload, Token) ->
    DCIDLen = byte_size(DCID),
    SCIDLen = byte_size(SCID),
    PNLen = packet_number_length(PacketNumber),
    PNBin = encode_pn_bytes(PacketNumber, PNLen),

    %% First byte: Form=1, Fixed=1, LongPacketType=Type(2bits), Reserved=00, PNLen
    FirstByte = 16#c0 bor (Type bsl 4) bor (PNLen - 1),

    TokenBin = case Type of
        ?INITIAL_PACKET ->
            <<(quic_varint:encode(byte_size(Token)))/binary, Token/binary>>;
        _ ->
            <<>>
    end,

    %% Length field: covers PN + encrypted payload
    PayloadLen = PNLen + byte_size(Payload),

    Header = <<FirstByte:8, Version:32,
               DCIDLen:8, DCID/binary,
               SCIDLen:8, SCID/binary,
               TokenBin/binary,
               (quic_varint:encode(PayloadLen))/binary,
               PNBin/binary>>,
    <<Header/binary, Payload/binary>>.

decode_long_pn(FullBin, PktType, Version, DCID, SCID, Token, AfterToken) ->
    %% AfterToken starts with Length field (varint), then PN, then payload
    {Length, R1} = quic_varint:decode(AfterToken),
    %% Extract PNLen from first byte
    <<FirstByte:8, _/binary>> = FullBin,
    PNLen = (FirstByte band 16#03) + 1,
    <<PNBin:PNLen/binary, EncPayload/binary>> = R1,
    PacketNumber = decode_pn_bytes(PNBin, PNLen),

    %% RawHeader = everything up to and including PN
    %% Calculate header length: first byte + version + DCID len field + DCID + SCID len field + SCID
    %%   + token section + length varint + PN
    HeaderLen = byte_size(FullBin) - byte_size(AfterToken)
                + quic_varint:encode_len(Length) + PNLen,
    <<RawHeader:HeaderLen/binary, _/binary>> = FullBin,

    PayloadLen = Length - PNLen,
    <<Payload:PayloadLen/binary, Rest/binary>> = EncPayload,

    Pkt = #quic_packet{
        type = PktType,
        version = Version,
        dcid = DCID,
        scid = SCID,
        packet_number = PacketNumber,
        token = Token,
        payload = Payload,
        raw_header = RawHeader
    },
    {ok, Pkt, Rest}.

long_packet_type(?INITIAL_PACKET, ?QUIC_V1) -> initial;
long_packet_type(?ZERO_RTT_PACKET, ?QUIC_V1) -> zero_rtt;
long_packet_type(?HANDSHAKE_PACKET, ?QUIC_V1) -> handshake;
long_packet_type(?RETRY_PACKET, ?QUIC_V1) -> retry;
%% QUIC v2 (RFC 9369)
long_packet_type(?INITIAL_PACKET_V2, ?QUIC_V2) -> initial;
long_packet_type(?ZERO_RTT_PACKET_V2, ?QUIC_V2) -> zero_rtt;
long_packet_type(?HANDSHAKE_PACKET_V2, ?QUIC_V2) -> handshake;
long_packet_type(?RETRY_PACKET_V2, ?QUIC_V2) -> retry;
long_packet_type(Type, _Version) -> {unknown, Type}.

encode_pn_bytes(PN, 1) -> <<PN:8>>;
encode_pn_bytes(PN, 2) -> <<PN:16>>;
encode_pn_bytes(PN, 3) -> <<PN:24>>;
encode_pn_bytes(PN, 4) -> <<PN:32>>.

decode_pn_bytes(<<PN:8>>, 1) -> PN;
decode_pn_bytes(<<PN:16>>, 2) -> PN;
decode_pn_bytes(<<PN:24>>, 3) -> PN;
decode_pn_bytes(<<PN:32>>, 4) -> PN.

decode_versions(<<>>) -> [];
decode_versions(<<V:32, Rest/binary>>) -> [V | decode_versions(Rest)].
