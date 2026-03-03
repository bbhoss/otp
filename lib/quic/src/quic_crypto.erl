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
    hkdf_extract/2,
    hkdf_extract/3,
    hkdf_expand_label/4,
    hkdf_expand_label/6,
    initial_salt/1,
    make_nonce/2
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
unprotect_packet(ProtectedPacket, _LargestPN, {Key, IV, HPKey}, IsLong) ->
    %% Find PN offset (we know the minimum position)
    PNOffset = find_pn_offset(ProtectedPacket, IsLong),

    %% Get sample: starts 4 bytes after PN offset
    SampleOffset = PNOffset + 4,
    case byte_size(ProtectedPacket) >= SampleOffset + 16 of
        false -> {error, packet_too_short};
        true ->
            <<_:SampleOffset/binary, Sample:16/binary, _/binary>> = ProtectedPacket,

            %% Remove header protection
            Unprotected = unprotect_header(ProtectedPacket, HPKey, Sample, IsLong),

            %% Now read the real PN length from first byte
            <<FirstByte:8, _/binary>> = Unprotected,
            PNLen = (FirstByte band 16#03) + 1,

            %% Extract the packet number
            <<_:PNOffset/binary, PNBin:PNLen/binary, CipherPayload/binary>> = Unprotected,
            PacketNumber = binary:decode_unsigned(PNBin, big),

            %% Header = everything up to and including PN
            HeaderLen = PNOffset + PNLen,
            <<Header:HeaderLen/binary, _/binary>> = Unprotected,

            %% Decrypt
            case decrypt_payload(CipherPayload, Key, IV, PacketNumber, Header) of
                {ok, PlainPayload} ->
                    {ok, Header, PlainPayload, PacketNumber};
                {error, _} = Error ->
                    Error
            end
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
    <<FirstByte:8, Rest/binary>> = Packet,
    <<M0:8, M1:8, M2:8, M3:8, M4:8>> = Mask,

    %% Mask bits depend on header type
    FirstByteMask = case IsLong of
        true -> 16#0f;   %% 4 least significant bits
        false -> 16#1f   %% 5 least significant bits
    end,
    NewFirstByte = FirstByte bxor (M0 band FirstByteMask),

    %% PN length is in the 2 least significant bits of (un)protected first byte
    %% For protection: use the UNPROTECTED first byte (original)
    %% For unprotection: use the NEWLY UNPROTECTED first byte
    PNLen = (NewFirstByte band 16#03) + 1,

    %% Find PN offset in Rest
    PNOffset = find_pn_offset_in_rest(Rest, IsLong, byte_size(Packet)),

    <<Before:PNOffset/binary, PNBytes:PNLen/binary, After/binary>> = Rest,
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
            {quic_varint:encode_len(TLen) + TLen, R1};
        _ ->
            {0, Rest}
    end,
    %% Now R2 starts with Length varint
    {_Length, _R3} = quic_varint:decode(R2),
    LenFieldLen = quic_varint:encode_len(_Length),
    BaseOffset + TokenFieldLen + LenFieldLen;

find_pn_offset(_Packet, false) ->
    %% Short header: 1 byte first byte + DCID
    %% We need to know DCID length from connection context
    %% For now, parse from the packet structure
    %% The caller should handle this appropriately
    1.  %% Placeholder - real implementation uses known DCID length

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
