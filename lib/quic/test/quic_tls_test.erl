-module(quic_tls_test).
-include("quic.hrl").
-export([run/0, test_packet_roundtrip/0]).

run() ->
    application:ensure_all_started(quic),
    LP = #transport_params{},

    {ok, ServerTLS} = quic_tls:init_server(
        "lib/quic/examples/cert.pem", "lib/quic/examples/key.pem",
        [<<"chat">>], LP),

    {ok, ClientTLS} = quic_tls:init_client([<<"chat">>], LP),
    {CHBin, ClientTLS2} = quic_tls:get_client_hello(ClientTLS),
    io:format("CH size: ~p~n", [byte_size(CHBin)]),

    {ok, ServerActions, _ServerTLS2} = quic_tls:handle_crypto_data(CHBin, initial, ServerTLS),
    io:format("Server actions: ~p~n", [[element(1,A) || A <- ServerActions]]),

    [SH] = [X || {send_crypto, initial, X} <- ServerActions],
    [HS] = [X || {send_crypto, handshake, X} <- ServerActions],
    io:format("SH size: ~p, HS size: ~p~n", [byte_size(SH), byte_size(HS)]),

    {ok, CA1, ClientTLS3} = quic_tls:handle_crypto_data(SH, initial, ClientTLS2),
    io:format("Client after SH: ~p~n", [[element(1,A) || A <- CA1]]),

    case quic_tls:handle_crypto_data(HS, handshake, ClientTLS3) of
        {ok, CA2, _ClientTLS4} ->
            io:format("Client after HS: ~p~n", [[element(1,A) || A <- CA2]]),
            io:format("HANDSHAKE SUCCESS!~n"),

            %% Compare handshake keys
            [ClientHSKeyMap] = [K || {handshake_keys, K} <- CA1],
            [ServerHSKeyMap] = [K || {handshake_keys, K} <- ServerActions],
            io:format("Client view HS keys match: ~p~n", [ClientHSKeyMap =:= ServerHSKeyMap]),

            %% Compare application keys
            [ClientAppKeyMap] = [K || {application_keys, K} <- CA2],
            [ServerAppKeyMap] = [K || {application_keys, K} <- ServerActions],
            io:format("App keys match: ~p~n", [ClientAppKeyMap =:= ServerAppKeyMap]),
            ok;
        {error, E2} ->
            io:format("Client HS FAILED: ~p~n", [E2]),
            error
    end.

test_packet_roundtrip() ->
    %% Test that our packet protection/unprotection is correct
    %% Simulate what the server does: encode + protect a Handshake packet,
    %% then try to decrypt it with the handshake keys
    application:ensure_all_started(quic),
    LP = #transport_params{},

    {ok, ServerTLS} = quic_tls:init_server(
        "lib/quic/examples/cert.pem", "lib/quic/examples/key.pem",
        [<<"chat">>], LP),
    {ok, ClientTLS} = quic_tls:init_client([<<"chat">>], LP),
    {CHBin, ClientTLS2} = quic_tls:get_client_hello(ClientTLS),

    {ok, ServerActions, _} = quic_tls:handle_crypto_data(CHBin, initial, ServerTLS),

    [SH] = [X || {send_crypto, initial, X} <- ServerActions],
    [HSData] = [X || {send_crypto, handshake, X} <- ServerActions],
    [HSKeyMap] = [K || {handshake_keys, K} <- ServerActions],

    %% Client derives handshake keys
    {ok, _CA1, _ClientTLS3} = quic_tls:handle_crypto_data(SH, initial, ClientTLS2),

    %% Server encrypts Handshake packet
    #{server := ServerHSKeys} = HSKeyMap,
    #{client := ClientHSKeys} = HSKeyMap,

    DCID = <<>>,  %% client has no SCID
    SCID = crypto:strong_rand_bytes(8),

    %% Build handshake crypto frame
    CryptoFrame = quic_frame:encode({crypto, 0, HSData}),

    %% Encode handshake packet (plaintext)
    PlainPacket = quic_packet:encode_handshake(DCID, SCID, 0, CryptoFrame),
    io:format("Plain Handshake packet: ~p bytes~n", [byte_size(PlainPacket)]),
    io:format("First 20: ~w~n", [binary:part(PlainPacket, 0, min(20, byte_size(PlainPacket)))]),

    %% Protect the packet (same as quic_connection:protect_long_packet)
    ProtectedPacket = protect_long_packet_test(PlainPacket, 0, ServerHSKeys),
    io:format("Protected Handshake packet: ~p bytes~n", [byte_size(ProtectedPacket)]),
    io:format("First 20: ~w~n", [binary:part(ProtectedPacket, 0, min(20, byte_size(ProtectedPacket)))]),

    %% Now try to decrypt with client keys (using server keys for decryption since
    %% the server encrypted with server keys)
    case quic_crypto:unprotect_packet(ProtectedPacket, 0, ServerHSKeys, true) of
        {ok, _Header, Payload, PN} ->
            io:format("Decryption SUCCESS! PN=~p, Payload=~p bytes~n", [PN, byte_size(Payload)]),
            case quic_frame:decode_all(Payload) of
                {ok, Frames} ->
                    io:format("Decoded frames: ~p~n", [[element(1,F) || F <- Frames]]),
                    ok;
                {error, E} ->
                    io:format("Frame decode failed: ~p~n", [E]),
                    error
            end;
        {error, E} ->
            io:format("Decryption FAILED: ~p~n", [E]),
            error
    end.

protect_long_packet_test(Packet, PN, {Key, IV, HPKey}) ->
    PNOffset = find_long_pn_offset_test(Packet),
    <<FB:8, _/binary>> = Packet,
    PNLen = (FB band 16#03) + 1,
    HeaderLen = PNOffset + PNLen,
    <<Header:HeaderLen/binary, Payload/binary>> = Packet,

    Nonce = quic_crypto:make_nonce(IV, PN),
    {CipherText, Tag} = crypto:crypto_one_time_aead(
        aes_128_gcm, Key, Nonce, Payload, Header, 16, true),
    CipherPayload = <<CipherText/binary, Tag/binary>>,

    SampleStart = 4 - PNLen,
    <<_:SampleStart/binary, Sample:16/binary, _/binary>> = CipherPayload,

    <<Mask:5/binary, _/binary>> = crypto:crypto_one_time(aes_128_ecb, HPKey, Sample, true),
    <<M0:8, M1:8, M2:8, M3:8, M4:8>> = Mask,

    NewFB = FB bxor (M0 band 16#0f),
    <<_:PNOffset/binary, PNBytes:PNLen/binary, _/binary>> = Packet,
    MaskPN = binary:part(<<M1, M2, M3, M4>>, 0, PNLen),
    NewPN = crypto:exor(PNBytes, MaskPN),

    <<_Pre:1/binary, Mid:(PNOffset-1)/binary, _:PNLen/binary, _/binary>> = Packet,
    <<NewFB:8, Mid/binary, NewPN/binary, CipherPayload/binary>>.

find_long_pn_offset_test(Packet) ->
    <<_FB:8, _Version:32, DCIDLen:8, _DCID:DCIDLen/binary,
      SCIDLen:8, _SCID:SCIDLen/binary, Rest/binary>> = Packet,
    BaseOffset = 1 + 4 + 1 + DCIDLen + 1 + SCIDLen,
    <<FBx:8, _/binary>> = Packet,
    Type = (FBx band 16#30) bsr 4,
    TokenFieldLen = case Type of
        0 -> %% Initial
            {TLen, _} = quic_varint:decode(Rest),
            quic_varint:encode_len(TLen) + TLen;
        _ -> 0
    end,
    AfterToken = binary:part(Rest, TokenFieldLen, byte_size(Rest) - TokenFieldLen),
    {_Length, _} = quic_varint:decode(AfterToken),
    LenFieldLen = quic_varint:encode_len(_Length),
    BaseOffset + TokenFieldLen + LenFieldLen.
