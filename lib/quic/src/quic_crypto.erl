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

%% QUIC Cryptographic Operations (RFC 9001)
%%
%% This module implements QUIC-specific cryptographic operations:
%% - Initial key derivation from Connection IDs
%% - AEAD encryption/decryption
%% - Header protection/unprotection
%% - HKDF key derivation with QUIC-specific labels
%%
%% Uses Erlang's crypto module for the underlying primitives.

-module(quic_crypto).

-include("quic.hrl").

-export([
    derive_initial_keys/1,
    derive_initial_keys/2,
    derive_keys/3,
    derive_keys/4,
    encrypt_payload/5,
    decrypt_payload/5,
    protect_header/4,
    unprotect_header/4,
    protect_packet/4,
    unprotect_packet/4,
    unprotect_packet/5,
    reconstruct_pn/3,
    hkdf_extract/2,
    hkdf_extract/3,
    hkdf_expand_label/4,
    hkdf_expand_label/6,
    initial_salt/1,
    make_nonce/2,
    next_key_update/3
]).

%% Key set: {Key, IV, HP_Key}
-type key_set() :: {binary(), binary(), binary()}.
%% Cipher info: {aead_cipher, hash_algo, key_length}
-type cipher_info() :: {aes_128_gcm | aes_256_gcm | chacha20_poly1305, sha256 | sha384, pos_integer()}.

%% ===================================================================
%% Initial Key Derivation (RFC 9001, Section 5.2)
%% ===================================================================

%% @doc Derive initial keys from the Destination Connection ID.
%% Uses QUIC v1 salt by default.
-spec derive_initial_keys(binary()) ->
    #{client := key_set(), server := key_set()}.
derive_initial_keys(DCID) ->
    derive_initial_keys(DCID, ?QUIC_V1).

-spec derive_initial_keys(binary(), non_neg_integer()) ->
    #{client := key_set(), server := key_set()}.
derive_initial_keys(DCID, Version) ->
    Salt = initial_salt(Version),

    %% Initial secret
    InitialSecret = hkdf_extract(Salt, DCID),

    %% Client initial secret - uses "tls13 client in" label
    ClientSecret = hkdf_expand_label(InitialSecret, <<"client in">>,
                                     <<>>, 32, sha256, ?TLS13_LABEL_PREFIX),
    ClientKeys = derive_key_set(ClientSecret, sha256, 16, Version),

    %% Server initial secret - uses "tls13 server in" label
    ServerSecret = hkdf_expand_label(InitialSecret, <<"server in">>,
                                     <<>>, 32, sha256, ?TLS13_LABEL_PREFIX),
    ServerKeys = derive_key_set(ServerSecret, sha256, 16, Version),

    #{client => ClientKeys, server => ServerKeys}.

%% @doc Derive key, IV, and HP key from a traffic secret.
-spec derive_keys(binary(), atom(), pos_integer()) -> key_set().
derive_keys(Secret, HashAlgo, KeyLen) ->
    derive_keys(Secret, HashAlgo, KeyLen, ?QUIC_V1).

-spec derive_keys(binary(), atom(), pos_integer(), non_neg_integer()) -> key_set().
derive_keys(Secret, HashAlgo, KeyLen, Version) ->
    derive_key_set(Secret, HashAlgo, KeyLen, Version).

%% @doc Derive next-generation traffic secret and keys for key update (RFC 9001 Section 6).
%% Returns {NewSecret, {NewKey, NewIV, OldHP}} - HP key does NOT change during key updates.
-spec next_key_update(binary(), atom(), pos_integer()) -> {binary(), key_set()}.
next_key_update(CurrentSecret, HashAlgo, KeyLen) ->
    HashLen = hash_length(HashAlgo),
    NextSecret = hkdf_expand_label(CurrentSecret, ?QUIC_V1_KU_LABEL, <<>>, HashLen, HashAlgo, ?TLS13_LABEL_PREFIX),
    {Key, IV, _HP} = derive_key_set(NextSecret, HashAlgo, KeyLen, ?QUIC_V1),
    {NextSecret, {Key, IV}}.

%% ===================================================================
%% AEAD Encryption/Decryption (RFC 9001, Section 5.3)
%% ===================================================================

%% @doc Encrypt a QUIC payload using AEAD.
%% AAD is the packet header (everything before the encrypted payload).
-spec encrypt_payload(binary(), binary(), binary(), non_neg_integer(), binary()) -> binary().
encrypt_payload(PlainText, Key, IV, PacketNumber, AAD) ->
    Nonce = make_nonce(IV, PacketNumber),
    {CipherText, Tag} = crypto:crypto_one_time_aead(
        aead_cipher(byte_size(Key)), Key, Nonce, PlainText, AAD, 16, true),
    <<CipherText/binary, Tag/binary>>.

%% @doc Decrypt a QUIC payload using AEAD.
-spec decrypt_payload(binary(), binary(), binary(), non_neg_integer(), binary()) ->
    {ok, binary()} | {error, decrypt_failed}.
decrypt_payload(CipherTextAndTag, Key, IV, PacketNumber, AAD) ->
    Nonce = make_nonce(IV, PacketNumber),
    TagLen = 16,
    CTLen = byte_size(CipherTextAndTag) - TagLen,
    <<CipherText:CTLen/binary, Tag:TagLen/binary>> = CipherTextAndTag,
    case crypto:crypto_one_time_aead(
            aead_cipher(byte_size(Key)), Key, Nonce, CipherText, AAD, Tag, false) of
        error -> {error, decrypt_failed};
        PlainText -> {ok, PlainText}
    end.

%% ===================================================================
%% Header Protection (RFC 9001, Section 5.4)
%% ===================================================================

%% @doc Apply header protection to an encoded packet.
%% HPKey is the header protection key.
%% IsLong indicates whether this is a long header packet.
-spec protect_header(binary(), binary(), binary(), boolean()) -> binary().
protect_header(Packet, HPKey, _Sample, _IsLong) when byte_size(HPKey) =:= 0 ->
    Packet;
protect_header(Packet, HPKey, Sample, IsLong) ->
    Mask = hp_mask(HPKey, Sample),
    apply_header_protection(Packet, Mask, IsLong).

%% @doc Remove header protection from an encoded packet.
-spec unprotect_header(binary(), binary(), binary(), boolean()) -> binary().
unprotect_header(Packet, HPKey, Sample, IsLong) ->
    Mask = hp_mask(HPKey, Sample),
    apply_header_protection(Packet, Mask, IsLong).

%% @doc Full packet protection: encrypt payload + protect header.
%% Takes an unprotected packet (header + plaintext payload) and returns
%% the fully protected packet.
-spec protect_packet(binary(), non_neg_integer(), key_set(), boolean()) -> binary().
protect_packet(UnprotectedPacket, PacketNumber, {Key, IV, HPKey}, IsLong) ->
    %% Find the PN offset and length in the header
    {PNOffset, PNLen} = find_pn_location(UnprotectedPacket, IsLong),

    %% Split into header (including PN) and payload
    HeaderLen = PNOffset + PNLen,
    <<Header:HeaderLen/binary, PlainPayload/binary>> = UnprotectedPacket,

    %% Encrypt the payload
    CipherPayload = encrypt_payload(PlainPayload, Key, IV, PacketNumber, Header),

    %% Get sample for header protection (4 bytes after PN start + 4-PNLen offset)
    SampleOffset = PNOffset + 4,
    <<_:SampleOffset/binary, Sample:16/binary, _/binary>> = CipherPayload,

    %% Construct packet before header protection
    FullPacket = <<Header/binary, CipherPayload/binary>>,

    %% Apply header protection
    protect_header(FullPacket, HPKey, Sample, IsLong).

%% @doc Full packet unprotection: unprotect header + decrypt payload.
-spec unprotect_packet(binary(), non_neg_integer(), key_set(), boolean()) ->
    {ok, binary(), binary(), non_neg_integer()} | {error, term()}.
unprotect_packet(ProtectedPacket, LargestPN, {Key, IV, HPKey}, IsLong) ->
    PNOffset = find_pn_offset(ProtectedPacket, IsLong),

    SampleOffset = PNOffset + 4,
    case byte_size(ProtectedPacket) >= SampleOffset + 16 of
        false -> {error, packet_too_short};
        true ->
            <<_:SampleOffset/binary, Sample:16/binary, _/binary>> = ProtectedPacket,

            Unprotected = unprotect_header(ProtectedPacket, HPKey, Sample, IsLong),

            <<FirstByte:8, _/binary>> = Unprotected,
            PNLen = (FirstByte band 16#03) + 1,

            <<_:PNOffset/binary, PNBin:PNLen/binary, CipherPayload/binary>> = Unprotected,
            TruncatedPN = binary:decode_unsigned(PNBin, big),
            PacketNumber = reconstruct_pn(TruncatedPN, PNLen, LargestPN),

            HeaderLen = PNOffset + PNLen,
            <<Header:HeaderLen/binary, _/binary>> = Unprotected,

            case decrypt_payload(CipherPayload, Key, IV, PacketNumber, Header) of
                {ok, PlainPayload} ->
                    {ok, Header, PlainPayload, PacketNumber};
                {error, _} = Error ->
                    Error
            end
    end.

%% @doc Full packet unprotection for short header with known DCID length.
-spec unprotect_packet(binary(), non_neg_integer(), key_set(), boolean(), non_neg_integer()) ->
    {ok, binary(), binary(), non_neg_integer()} | {error, term()}.
unprotect_packet(ProtectedPacket, LargestPN, {Key, IV, HPKey}, false = IsLong, DCIDLen) ->
    PNOffset = find_pn_offset(ProtectedPacket, false, DCIDLen),

    SampleOffset = PNOffset + 4,
    case byte_size(ProtectedPacket) >= SampleOffset + 16 of
        false -> {error, packet_too_short};
        true ->
            <<_:SampleOffset/binary, Sample:16/binary, _/binary>> = ProtectedPacket,
            <<ProtFirstByte:8, _/binary>> = ProtectedPacket,
            Mask = hp_mask(HPKey, Sample),
            <<M0:8, _:4/binary>> = Mask,
            Unprotected = apply_header_protection(ProtectedPacket, Mask, IsLong, DCIDLen),
            <<FirstByte:8, _/binary>> = Unprotected,
            PNLen = (FirstByte band 16#03) + 1,
            <<_:PNOffset/binary, PNBin:PNLen/binary, CipherPayload/binary>> = Unprotected,
            TruncatedPN = binary:decode_unsigned(PNBin, big),
            PacketNumber = reconstruct_pn(TruncatedPN, PNLen, LargestPN),
            HeaderLen = PNOffset + PNLen,
            <<Header:HeaderLen/binary, _/binary>> = Unprotected,
            case decrypt_payload(CipherPayload, Key, IV, PacketNumber, Header) of
                {ok, PlainPayload} ->
                    {ok, Header, PlainPayload, PacketNumber};
                {error, _} ->
                    {error, {decrypt_failed, #{prot_fb => ProtFirstByte,
                                               mask0 => M0,
                                               unprot_fb => FirstByte,
                                               pn_len => PNLen,
                                               truncated_pn => TruncatedPN,
                                               reconstructed_pn => PacketNumber,
                                               largest_pn => LargestPN,
                                               pn_offset => PNOffset,
                                               sample_hex => binary:encode_hex(Sample),
                                               pkt_size => byte_size(ProtectedPacket)}}}
            end
    end.

%% ===================================================================
%% Packet Number Reconstruction (RFC 9000, Appendix A)
%% ===================================================================

-spec reconstruct_pn(non_neg_integer(), 1..4, non_neg_integer()) -> non_neg_integer().
reconstruct_pn(TruncatedPN, PNLen, LargestPN) ->
    PNNBits = PNLen * 8,
    ExpectedPN = LargestPN + 1,
    PNWin = 1 bsl PNNBits,
    PNHWin = PNWin div 2,
    PNMask = PNWin - 1,
    CandidatePN = (ExpectedPN band (bnot PNMask)) bor TruncatedPN,
    if
        CandidatePN =< ExpectedPN - PNHWin andalso
        CandidatePN < (1 bsl 62) - PNWin ->
            CandidatePN + PNWin;
        CandidatePN > ExpectedPN + PNHWin andalso
        CandidatePN >= PNWin ->
            CandidatePN - PNWin;
        true ->
            CandidatePN
    end.

%% ===================================================================
%% HKDF Functions
%% ===================================================================

%% @doc HKDF-Extract
-spec hkdf_extract(binary(), binary()) -> binary().
hkdf_extract(Salt, IKM) ->
    crypto:mac(hmac, sha256, Salt, IKM).

%% @doc HKDF-Extract with specified hash
-spec hkdf_extract(binary(), binary(), atom()) -> binary().
hkdf_extract(Salt, IKM, HashAlgo) ->
    crypto:mac(hmac, HashAlgo, Salt, IKM).

%% @doc HKDF-Expand-Label with QUIC v1 prefix
-spec hkdf_expand_label(binary(), binary(), binary(), pos_integer()) -> binary().
hkdf_expand_label(Secret, Label, Context, Length) ->
    hkdf_expand_label(Secret, Label, Context, Length, sha256, ?TLS13_LABEL_PREFIX).

%% @doc HKDF-Expand-Label with specified hash and prefix
-spec hkdf_expand_label(binary(), binary(), binary(), pos_integer(),
                         atom(), binary()) -> binary().
hkdf_expand_label(Secret, Label, Context, Length, HashAlgo, LabelPrefix) ->
    %% HkdfLabel struct:
    %%   uint16 length;
    %%   opaque label<7..255> = "tls13 " or "quic " + Label;
    %%   opaque context<0..255> = Context;
    FullLabel = <<LabelPrefix/binary, Label/binary>>,
    LabelLen = byte_size(FullLabel),
    ContextLen = byte_size(Context),
    Info = <<Length:16,
             LabelLen:8, FullLabel/binary,
             ContextLen:8, Context/binary>>,
    hkdf_expand(Secret, Info, Length, HashAlgo).

%% @doc Get the initial salt for a QUIC version.
-spec initial_salt(non_neg_integer()) -> binary().
initial_salt(?QUIC_V1) -> ?QUIC_V1_INITIAL_SALT;
initial_salt(?QUIC_V2) -> ?QUIC_V2_INITIAL_SALT.

%% @doc Compute AEAD nonce by XORing IV with left-padded packet number.
-spec make_nonce(binary(), non_neg_integer()) -> binary().
make_nonce(IV, PacketNumber) ->
    IVLen = byte_size(IV),
    PNBin = <<PacketNumber:64>>,
    %% Left-pad PN to IV length, then XOR
    PadLen = IVLen - 8,
    PaddedPN = <<0:(PadLen * 8), PNBin/binary>>,
    crypto:exor(IV, PaddedPN).

%% ===================================================================
%% Internal Functions
%% ===================================================================

%% Get key/iv/hp labels for each QUIC version
key_label(?QUIC_V1) -> ?QUIC_V1_KEY_LABEL;
key_label(?QUIC_V2) -> ?QUIC_V2_KEY_LABEL;
key_label(_) -> ?QUIC_V1_KEY_LABEL.

iv_label(?QUIC_V1) -> ?QUIC_V1_IV_LABEL;
iv_label(?QUIC_V2) -> ?QUIC_V2_IV_LABEL;
iv_label(_) -> ?QUIC_V1_IV_LABEL.

hp_label(?QUIC_V1) -> ?QUIC_V1_HP_LABEL;
hp_label(?QUIC_V2) -> ?QUIC_V2_HP_LABEL;
hp_label(_) -> ?QUIC_V1_HP_LABEL.

derive_key_set(Secret, HashAlgo, KeyLen, Version) ->
    %% All HKDF-Expand-Label calls use "tls13 " prefix (per TLS 1.3 RFC 8446)
    %% The version-specific part is in the label itself (e.g. "quic key" vs "quicv2 key")
    Key = hkdf_expand_label(Secret, key_label(Version), <<>>, KeyLen, HashAlgo, ?TLS13_LABEL_PREFIX),
    IV = hkdf_expand_label(Secret, iv_label(Version), <<>>, 12, HashAlgo, ?TLS13_LABEL_PREFIX),
    HP = hkdf_expand_label(Secret, hp_label(Version), <<>>, KeyLen, HashAlgo, ?TLS13_LABEL_PREFIX),
    {Key, IV, HP}.

%% HKDF-Expand (RFC 5869)
hkdf_expand(PRK, Info, Length, HashAlgo) ->
    HashLen = hash_length(HashAlgo),
    N = ceiling(Length, HashLen),
    OKM = hkdf_expand_loop(PRK, Info, HashAlgo, N, 1, <<>>, <<>>),
    <<Result:Length/binary, _/binary>> = OKM,
    Result.

hkdf_expand_loop(_PRK, _Info, _HashAlgo, N, I, _Prev, Acc) when I > N ->
    Acc;
hkdf_expand_loop(PRK, Info, HashAlgo, N, I, Prev, Acc) ->
    T = crypto:mac(hmac, HashAlgo, PRK, <<Prev/binary, Info/binary, I:8>>),
    hkdf_expand_loop(PRK, Info, HashAlgo, N, I + 1, T, <<Acc/binary, T/binary>>).

ceiling(X, Y) -> (X + Y - 1) div Y.

hash_length(sha256) -> 32;
hash_length(sha384) -> 48;
hash_length(sha512) -> 64.

%% Determine AEAD cipher from key length
aead_cipher(16) -> aes_128_gcm;
aead_cipher(32) -> aes_256_gcm.

%% Header protection mask generation (RFC 9001, Section 5.4.3)
hp_mask(HPKey, Sample) when byte_size(HPKey) =:= 16 ->
    %% AES-ECB based HP
    <<Mask:5/binary, _/binary>> = crypto:crypto_one_time(aes_128_ecb, HPKey, Sample, true),
    Mask;
hp_mask(HPKey, Sample) when byte_size(HPKey) =:= 32 ->
    %% AES-256-ECB or ChaCha20 based HP
    <<Mask:5/binary, _/binary>> = crypto:crypto_one_time(aes_256_ecb, HPKey, Sample, true),
    Mask.

%% Apply/remove header protection (same operation, XOR is its own inverse)
apply_header_protection(Packet, Mask, IsLong) ->
    PNOffset = find_pn_offset(Packet, IsLong),
    apply_header_protection_at(Packet, Mask, IsLong, PNOffset).

apply_header_protection(Packet, Mask, IsLong, DCIDLen) ->
    PNOffset = find_pn_offset(Packet, IsLong, DCIDLen),
    apply_header_protection_at(Packet, Mask, IsLong, PNOffset).

apply_header_protection_at(Packet, Mask, IsLong, PNOffset) ->
    <<FirstByte:8, Rest/binary>> = Packet,
    <<M0:8, M1:8, M2:8, M3:8, M4:8>> = Mask,

    %% Mask bits depend on header type
    FirstByteMask = case IsLong of
        true -> 16#0f;   %% 4 least significant bits
        false -> 16#1f   %% 5 least significant bits
    end,
    NewFirstByte = FirstByte bxor (M0 band FirstByteMask),

    %% PN length is in the 2 least significant bits of (un)protected first byte
    PNLen = (NewFirstByte band 16#03) + 1,

    %% PNOffset is from start of packet, subtract 1 for offset in Rest
    RestPNOffset = PNOffset - 1,

    <<Before:RestPNOffset/binary, PNBytes:PNLen/binary, After/binary>> = Rest,
    MaskBytes = binary:part(<<M1, M2, M3, M4>>, 0, PNLen),
    NewPNBytes = crypto:exor(PNBytes, MaskBytes),

    <<NewFirstByte:8, Before/binary, NewPNBytes/binary, After/binary>>.

%% Find the PN offset (position in packet where PN starts)
find_pn_offset(Packet, true) ->
    %% Long header: 1 byte first byte + 4 bytes version + 1 byte DCID len + DCID + 1 byte SCID len + SCID
    %% + optional token (Initial) + length varint
    <<_FirstByte:8, _Version:32, DCIDLen:8, _DCID:DCIDLen/binary,
      SCIDLen:8, _SCID:SCIDLen/binary, Rest/binary>> = Packet,
    BaseOffset = 1 + 4 + 1 + DCIDLen + 1 + SCIDLen,
    %% Check packet type for token
    <<FB:8, _/binary>> = Packet,
    Type = (FB band 16#30) bsr 4,
    {TokenFieldLen, R2} = case Type of
        ?INITIAL_PACKET ->
            {TLen, R1} = quic_varint:decode(Rest),
            %% Actual varint length on wire = bytes consumed
            TokenVarIntLen = byte_size(Rest) - byte_size(R1),
            <<_Token:TLen/binary, AfterToken/binary>> = R1,
            {TokenVarIntLen + TLen, AfterToken};
        _ ->
            {0, Rest}
    end,
    %% Now R2 starts with Length varint
    {_Length, R3} = quic_varint:decode(R2),
    %% Use actual on-wire varint length, not minimum encoding
    LenFieldLen = byte_size(R2) - byte_size(R3),
    BaseOffset + TokenFieldLen + LenFieldLen;

find_pn_offset(_Packet, false) ->
    %% Short header: 1 byte first byte + DCID
    %% Default: assumes empty DCID (only valid when DCID is empty)
    1.

find_pn_offset(_Packet, false, DCIDLen) ->
    %% Short header: 1 byte first byte + DCID
    1 + DCIDLen.

find_pn_offset_in_rest(_Rest, _IsLong, _PacketSize) ->
    %% This is the offset within Rest (after first byte) where PN starts
    %% For long headers: after version + DCID + SCID + token + length
    %% This is complex; we handle it in protect_packet/unprotect_packet
    %% which already know the correct offsets
    0.  %% Simplified for the XOR operation

%% Find PN location in unprotected packet (offset from start, length)
find_pn_location(Packet, true) ->
    PNOffset = find_pn_offset(Packet, true),
    <<FB:8, _/binary>> = Packet,
    PNLen = (FB band 16#03) + 1,
    {PNOffset, PNLen};
find_pn_location(Packet, false) ->
    <<FB:8, _/binary>> = Packet,
    PNLen = (FB band 16#03) + 1,
    %% For short header, PN follows DCID (whose length we set to find_pn_offset)
    PNOffset = find_pn_offset(Packet, false),
    {PNOffset, PNLen}.
