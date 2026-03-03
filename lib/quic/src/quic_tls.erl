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

%% QUIC TLS 1.3 Handshake Engine (RFC 9001)
%%
%% This module implements the TLS 1.3 handshake for QUIC. QUIC replaces
%% the TLS record layer - TLS handshake messages are carried in CRYPTO
%% frames instead. This module handles:
%%
%% Client flow: ClientHello -> process ServerHello+EE+Cert+CV+Fin -> send Finished
%% Server flow: process ClientHello -> send SH+EE+Cert+CV+Fin -> process client Finished
%%
%% Key schedule:
%%   Initial: derive_initial_keys(DCID)
%%   After ServerHello: handshake keys from shared ECDH secret
%%   After server Finished: application (1-RTT) keys
%%   After client Finished: handshake complete

-module(quic_tls).

-include("quic.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([
    init_client/2,
    init_server/3,
    handle_crypto_data/3,
    get_client_hello/1
]).

%% TLS state record
-record(tls_state, {
    role                :: client | server,
    %% Key exchange
    private_key         :: binary() | undefined,
    public_key          :: binary() | undefined,
    peer_public_key     :: binary() | undefined,
    shared_secret       :: binary() | undefined,
    %% Cipher suite negotiation
    cipher_suite = ?TLS_AES_128_GCM_SHA256 :: binary(),
    hash_algo = sha256  :: sha256 | sha384,
    key_length = 16     :: pos_integer(),
    %% ALPN
    alpn                :: [binary()],
    negotiated_alpn     :: binary() | undefined,
    %% Server name
    server_name         :: string() | undefined,
    %% Certificate
    cert_file           :: string() | undefined,
    key_file            :: string() | undefined,
    cert_chain = []     :: [binary()],
    private_sign_key    :: term() | undefined,
    %% Transport params
    local_params        :: #transport_params{},
    remote_params       :: #transport_params{} | undefined,
    %% Handshake transcript (accumulated messages for transcript hash)
    transcript = <<>>   :: binary(),
    %% Secrets
    early_secret        :: binary() | undefined,
    handshake_secret    :: binary() | undefined,
    client_hs_secret    :: binary() | undefined,
    server_hs_secret    :: binary() | undefined,
    master_secret       :: binary() | undefined,
    client_app_secret   :: binary() | undefined,
    server_app_secret   :: binary() | undefined,
    %% State tracking
    phase = start       :: start | wait_server_hello | wait_encrypted_extensions
                         | wait_certificate | wait_certificate_verify
                         | wait_finished | wait_client_finished | connected,
    %% Client Hello binary (needed for HelloRetryRequest handling)
    client_hello_bin    :: binary() | undefined,
    %% Random values
    client_random       :: binary() | undefined,
    server_random       :: binary() | undefined
}).

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Initialize TLS state for a QUIC client.
-spec init_client([binary()], #transport_params{}) ->
    {ok, #tls_state{}}.
init_client(ALPN, LocalParams) ->
    {PubKey, PrivKey} = crypto:generate_key(ecdh, x25519),
    State = #tls_state{
        role = client,
        private_key = PrivKey,
        public_key = PubKey,
        alpn = ALPN,
        local_params = LocalParams,
        phase = start
    },
    {ok, State}.

%% @doc Initialize TLS state for a QUIC server.
-spec init_server(string(), string(), [binary()]) ->
    {ok, #tls_state{}} | {error, term()}.
init_server(CertFile, KeyFile, ALPN) ->
    case load_cert_and_key(CertFile, KeyFile) of
        {ok, CertChain, PrivSignKey} ->
            {PubKey, PrivKey} = crypto:generate_key(ecdh, x25519),
            State = #tls_state{
                role = server,
                private_key = PrivKey,
                public_key = PubKey,
                cert_file = CertFile,
                key_file = KeyFile,
                cert_chain = CertChain,
                private_sign_key = PrivSignKey,
                alpn = ALPN,
                phase = start
            },
            {ok, State};
        {error, _} = Error ->
            Error
    end.

%% @doc Get the ClientHello binary from a client TLS state.
-spec get_client_hello(#tls_state{}) -> {binary(), #tls_state{}}.
get_client_hello(#tls_state{role = client} = State) ->
    ClientHello = build_client_hello(State),
    CHBin = encode_handshake(?TLS_CLIENT_HELLO, ClientHello),
    NewState = State#tls_state{
        client_hello_bin = CHBin,
        transcript = CHBin,
        phase = wait_server_hello
    },
    {CHBin, NewState}.

%% @doc Handle incoming CRYPTO frame data at a given encryption level.
%% Returns a list of actions the connection should take.
-spec handle_crypto_data(binary(), atom(), #tls_state{}) ->
    {ok, [tuple()], #tls_state{}} | {error, term()}.
handle_crypto_data(Data, Level, State) ->
    process_handshake_messages(Data, Level, State, []).

%% ===================================================================
%% Handshake Message Processing
%% ===================================================================

process_handshake_messages(<<>>, _Level, State, Actions) ->
    {ok, lists:reverse(Actions), State};
process_handshake_messages(<<Type:8, Len:24, Msg:Len/binary, Rest/binary>>,
                           Level, State, Actions) ->
    FullMsg = <<Type:8, Len:24, Msg/binary>>,
    case process_message(Type, Msg, Level, State) of
        {ok, NewActions, NewState} ->
            State2 = NewState#tls_state{
                transcript = <<(NewState#tls_state.transcript)/binary, FullMsg/binary>>
            },
            process_handshake_messages(Rest, Level, State2, NewActions ++ Actions);
        {error, _} = Error ->
            Error
    end;
process_handshake_messages(_Incomplete, _Level, State, Actions) ->
    %% Incomplete message - buffer for later
    {ok, lists:reverse(Actions), State}.

%% --- Client processing ---

%% Client receives ServerHello
process_message(?TLS_SERVER_HELLO, Msg, initial,
                #tls_state{role = client, phase = wait_server_hello} = State) ->
    case parse_server_hello(Msg) of
        {ok, CipherSuite, PeerPubKey, ServerRandom} ->
            {HashAlgo, KeyLen} = cipher_suite_info(CipherSuite),
            SharedSecret = crypto:compute_key(ecdh, PeerPubKey,
                                              State#tls_state.private_key, x25519),

            %% Compute transcript hash of CH + SH
            SHBin = <<2:8, (byte_size(Msg)):24, Msg/binary>>,
            Transcript = <<(State#tls_state.transcript)/binary, SHBin/binary>>,
            TranscriptHash = crypto:hash(HashAlgo, Transcript),

            %% Key schedule: derive handshake secrets
            EarlySecret = quic_crypto:hkdf_extract(
                <<0:(hash_length(HashAlgo) * 8)>>, <<0:(hash_length(HashAlgo) * 8)>>),
            DerivedSecret = derive_secret(EarlySecret, <<"derived">>, <<>>, HashAlgo),
            HandshakeSecret = quic_crypto:hkdf_extract(DerivedSecret, SharedSecret),

            ClientHSSecret = derive_secret(HandshakeSecret, <<"c hs traffic">>,
                                           TranscriptHash, HashAlgo),
            ServerHSSecret = derive_secret(HandshakeSecret, <<"s hs traffic">>,
                                           TranscriptHash, HashAlgo),

            ClientKeys = quic_crypto:derive_keys(ClientHSSecret, HashAlgo, KeyLen),
            ServerKeys = quic_crypto:derive_keys(ServerHSSecret, HashAlgo, KeyLen),

            State2 = State#tls_state{
                cipher_suite = CipherSuite,
                hash_algo = HashAlgo,
                key_length = KeyLen,
                peer_public_key = PeerPubKey,
                shared_secret = SharedSecret,
                server_random = ServerRandom,
                early_secret = EarlySecret,
                handshake_secret = HandshakeSecret,
                client_hs_secret = ClientHSSecret,
                server_hs_secret = ServerHSSecret,
                transcript = Transcript,
                phase = wait_encrypted_extensions
            },

            Actions = [
                {handshake_keys, #{
                    client => ClientKeys,
                    server => ServerKeys
                }}
            ],
            {ok, Actions, State2};
        {error, _} = Error ->
            Error
    end;

%% Client receives EncryptedExtensions
process_message(?TLS_ENCRYPTED_EXTENSIONS, Msg, handshake,
                #tls_state{role = client, phase = wait_encrypted_extensions} = State) ->
    {ALPN, RemoteParams} = parse_encrypted_extensions(Msg),
    State2 = State#tls_state{
        negotiated_alpn = ALPN,
        remote_params = RemoteParams,
        phase = wait_certificate
    },
    {ok, [], State2};

%% Client receives Certificate
process_message(?TLS_CERTIFICATE, _Msg, handshake,
                #tls_state{role = client, phase = wait_certificate} = State) ->
    %% For now, accept any certificate (verify_none)
    State2 = State#tls_state{phase = wait_certificate_verify},
    {ok, [], State2};

%% Client receives CertificateVerify
process_message(?TLS_CERTIFICATE_VERIFY, _Msg, handshake,
                #tls_state{role = client, phase = wait_certificate_verify} = State) ->
    %% For now, accept any signature (verify_none)
    State2 = State#tls_state{phase = wait_finished},
    {ok, [], State2};

%% Client receives server Finished
process_message(?TLS_FINISHED, Msg, handshake,
                #tls_state{role = client, phase = wait_finished} = State) ->
    HashAlgo = State#tls_state.hash_algo,
    KeyLen = State#tls_state.key_length,

    %% Verify server's Finished
    FinishedKey = quic_crypto:hkdf_expand_label(
        State#tls_state.server_hs_secret, <<"finished">>, <<>>,
        hash_length(HashAlgo), HashAlgo, <<"tls13 ">>),
    TranscriptHash = crypto:hash(HashAlgo, State#tls_state.transcript),
    ExpectedVerify = crypto:mac(hmac, HashAlgo, FinishedKey, TranscriptHash),

    case Msg =:= ExpectedVerify of
        false ->
            {error, finished_verify_failed};
        true ->
            %% Derive application keys
            FinMsg = <<20:8, (byte_size(Msg)):24, Msg/binary>>,
            FullTranscript = <<(State#tls_state.transcript)/binary, FinMsg/binary>>,
            SFTranscriptHash = crypto:hash(HashAlgo, FullTranscript),

            HandshakeSecret = State#tls_state.handshake_secret,
            DerivedSecret = derive_secret(HandshakeSecret, <<"derived">>, <<>>, HashAlgo),
            MasterSecret = quic_crypto:hkdf_extract(
                DerivedSecret, <<0:(hash_length(HashAlgo) * 8)>>),

            ClientAppSecret = derive_secret(MasterSecret, <<"c ap traffic">>,
                                            SFTranscriptHash, HashAlgo),
            ServerAppSecret = derive_secret(MasterSecret, <<"s ap traffic">>,
                                            SFTranscriptHash, HashAlgo),

            ClientAppKeys = quic_crypto:derive_keys(ClientAppSecret, HashAlgo, KeyLen),
            ServerAppKeys = quic_crypto:derive_keys(ServerAppSecret, HashAlgo, KeyLen),

            %% Build client Finished
            ClientFinKey = quic_crypto:hkdf_expand_label(
                State#tls_state.client_hs_secret, <<"finished">>, <<>>,
                hash_length(HashAlgo), HashAlgo, <<"tls13 ">>),
            ClientFinHash = crypto:hash(HashAlgo, FullTranscript),
            ClientFinVerify = crypto:mac(hmac, HashAlgo, ClientFinKey, ClientFinHash),
            ClientFinMsg = encode_handshake(?TLS_FINISHED, ClientFinVerify),

            State2 = State#tls_state{
                master_secret = MasterSecret,
                client_app_secret = ClientAppSecret,
                server_app_secret = ServerAppSecret,
                transcript = FullTranscript,
                phase = connected
            },

            Actions = [
                {application_keys, #{
                    client => ClientAppKeys,
                    server => ServerAppKeys
                }},
                {send_crypto, handshake, ClientFinMsg},
                {handshake_complete, State2#tls_state.negotiated_alpn,
                 State2#tls_state.remote_params}
            ],
            {ok, Actions, State2}
    end;

%% --- Server processing ---

%% Server receives ClientHello
process_message(?TLS_CLIENT_HELLO, Msg, initial,
                #tls_state{role = server, phase = start} = State) ->
    case parse_client_hello(Msg) of
        {ok, CipherSuite, PeerPubKey, ALPN, RemoteParams, ClientRandom, ServerName} ->
            {HashAlgo, KeyLen} = cipher_suite_info(CipherSuite),
            SharedSecret = crypto:compute_key(ecdh, PeerPubKey,
                                              State#tls_state.private_key, x25519),

            %% Build ServerHello
            ServerRandom = crypto:strong_rand_bytes(32),
            ServerHello = build_server_hello(CipherSuite,
                                             State#tls_state.public_key,
                                             ServerRandom),
            SHBin = encode_handshake(?TLS_SERVER_HELLO, ServerHello),

            %% Compute transcript: CH + SH
            CHBin = <<1:8, (byte_size(Msg)):24, Msg/binary>>,
            Transcript = <<CHBin/binary, SHBin/binary>>,
            TranscriptHash = crypto:hash(HashAlgo, Transcript),

            %% Key schedule
            EarlySecret = quic_crypto:hkdf_extract(
                <<0:(hash_length(HashAlgo) * 8)>>, <<0:(hash_length(HashAlgo) * 8)>>),
            DerivedSecret = derive_secret(EarlySecret, <<"derived">>, <<>>, HashAlgo),
            HandshakeSecret = quic_crypto:hkdf_extract(DerivedSecret, SharedSecret),

            ClientHSSecret = derive_secret(HandshakeSecret, <<"c hs traffic">>,
                                           TranscriptHash, HashAlgo),
            ServerHSSecret = derive_secret(HandshakeSecret, <<"s hs traffic">>,
                                           TranscriptHash, HashAlgo),

            ClientHSKeys = quic_crypto:derive_keys(ClientHSSecret, HashAlgo, KeyLen),
            ServerHSKeys = quic_crypto:derive_keys(ServerHSSecret, HashAlgo, KeyLen),

            %% Build EncryptedExtensions
            NegotiatedALPN = negotiate_alpn(ALPN, State#tls_state.alpn),
            LocalParams = State#tls_state.local_params,
            EEBin = encode_handshake(?TLS_ENCRYPTED_EXTENSIONS,
                                     build_encrypted_extensions(NegotiatedALPN, LocalParams)),

            %% Build Certificate
            CertBin = encode_handshake(?TLS_CERTIFICATE,
                                       build_certificate(State#tls_state.cert_chain)),

            %% Transcript after EE + Cert
            Transcript2 = <<Transcript/binary, EEBin/binary, CertBin/binary>>,

            %% Build CertificateVerify
            CVTranscriptHash = crypto:hash(HashAlgo, Transcript2),
            CVBin = encode_handshake(?TLS_CERTIFICATE_VERIFY,
                                     build_certificate_verify(
                                         State#tls_state.private_sign_key,
                                         CVTranscriptHash, HashAlgo)),

            Transcript3 = <<Transcript2/binary, CVBin/binary>>,

            %% Build server Finished
            FinishedKey = quic_crypto:hkdf_expand_label(
                ServerHSSecret, <<"finished">>, <<>>,
                hash_length(HashAlgo), HashAlgo, <<"tls13 ">>),
            FinTranscriptHash = crypto:hash(HashAlgo, Transcript3),
            FinVerify = crypto:mac(hmac, HashAlgo, FinishedKey, FinTranscriptHash),
            FinBin = encode_handshake(?TLS_FINISHED, FinVerify),

            Transcript4 = <<Transcript3/binary, FinBin/binary>>,

            %% Derive application keys
            DerivedSecret2 = derive_secret(HandshakeSecret, <<"derived">>, <<>>, HashAlgo),
            MasterSecret = quic_crypto:hkdf_extract(
                DerivedSecret2, <<0:(hash_length(HashAlgo) * 8)>>),
            SFTranscriptHash = crypto:hash(HashAlgo, Transcript4),
            ClientAppSecret = derive_secret(MasterSecret, <<"c ap traffic">>,
                                            SFTranscriptHash, HashAlgo),
            ServerAppSecret = derive_secret(MasterSecret, <<"s ap traffic">>,
                                            SFTranscriptHash, HashAlgo),
            ClientAppKeys = quic_crypto:derive_keys(ClientAppSecret, HashAlgo, KeyLen),
            ServerAppKeys = quic_crypto:derive_keys(ServerAppSecret, HashAlgo, KeyLen),

            %% Handshake data to send = EE + Cert + CV + Finished
            HandshakeData = <<EEBin/binary, CertBin/binary, CVBin/binary, FinBin/binary>>,

            State2 = State#tls_state{
                cipher_suite = CipherSuite,
                hash_algo = HashAlgo,
                key_length = KeyLen,
                peer_public_key = PeerPubKey,
                shared_secret = SharedSecret,
                client_random = ClientRandom,
                server_random = ServerRandom,
                negotiated_alpn = NegotiatedALPN,
                remote_params = RemoteParams,
                early_secret = EarlySecret,
                handshake_secret = HandshakeSecret,
                client_hs_secret = ClientHSSecret,
                server_hs_secret = ServerHSSecret,
                master_secret = MasterSecret,
                client_app_secret = ClientAppSecret,
                server_app_secret = ServerAppSecret,
                transcript = Transcript4,
                phase = wait_client_finished
            },

            Actions = [
                {send_crypto, initial, SHBin},
                {handshake_keys, #{
                    client => ClientHSKeys,
                    server => ServerHSKeys
                }},
                {send_crypto, handshake, HandshakeData},
                {application_keys, #{
                    client => ClientAppKeys,
                    server => ServerAppKeys
                }}
            ],
            {ok, Actions, State2};
        {error, _} = Error ->
            Error
    end;

%% Server receives client Finished
process_message(?TLS_FINISHED, Msg, handshake,
                #tls_state{role = server, phase = wait_client_finished} = State) ->
    HashAlgo = State#tls_state.hash_algo,

    %% Verify client's Finished
    FinishedKey = quic_crypto:hkdf_expand_label(
        State#tls_state.client_hs_secret, <<"finished">>, <<>>,
        hash_length(HashAlgo), HashAlgo, <<"tls13 ">>),
    TranscriptHash = crypto:hash(HashAlgo, State#tls_state.transcript),
    ExpectedVerify = crypto:mac(hmac, HashAlgo, FinishedKey, TranscriptHash),

    case Msg =:= ExpectedVerify of
        false ->
            {error, finished_verify_failed};
        true ->
            State2 = State#tls_state{phase = connected},
            Actions = [
                {handshake_complete, State2#tls_state.negotiated_alpn,
                 State2#tls_state.remote_params},
                send_handshake_done
            ],
            {ok, Actions, State2}
    end;

process_message(Type, _Msg, _Level, _State) ->
    {error, {unexpected_message, Type}}.

%% ===================================================================
%% TLS Message Building
%% ===================================================================

build_client_hello(#tls_state{public_key = PubKey, alpn = ALPN,
                               local_params = Params}) ->
    ClientRandom = crypto:strong_rand_bytes(32),
    SessionId = <<>>,  %% Not used in QUIC

    %% Cipher suites: TLS_AES_128_GCM_SHA256
    CipherSuites = <<?TLS_AES_128_GCM_SHA256/binary,
                     ?TLS_AES_256_GCM_SHA384/binary,
                     ?TLS_CHACHA20_POLY1305_SHA256/binary>>,

    %% Extensions
    Extensions = iolist_to_binary([
        %% Supported Versions (TLS 1.3)
        encode_extension(?TLS_EXT_SUPPORTED_VERSIONS,
                         <<1:8, 16#03, 16#04>>),  %% Length=1, TLS 1.3
        %% Supported Groups
        encode_extension(?TLS_EXT_SUPPORTED_GROUPS,
                         <<2:16, (?TLS_X25519):16>>),
        %% Key Share (x25519)
        encode_extension(?TLS_EXT_KEY_SHARE,
                         <<(2 + 2 + byte_size(PubKey)):16,
                           (?TLS_X25519):16, (byte_size(PubKey)):16, PubKey/binary>>),
        %% Signature Algorithms
        encode_extension(?TLS_EXT_SIGNATURE_ALGORITHMS,
                         <<6:16,
                           (?TLS_ECDSA_SECP256R1_SHA256):16,
                           (?TLS_RSA_PSS_RSAE_SHA256):16,
                           (?TLS_ED25519):16>>),
        %% ALPN
        encode_alpn_extension(ALPN),
        %% QUIC Transport Parameters
        encode_extension(?TLS_EXT_QUIC_TRANSPORT_PARAMS,
                         quic_transport_params:encode(Params))
    ]),

    %% ClientHello body
    <<?TLS_1_2/binary,                        %% Legacy version
      ClientRandom/binary,                     %% Random
      (byte_size(SessionId)):8, SessionId/binary, %% Session ID
      (byte_size(CipherSuites)):16, CipherSuites/binary, %% Cipher suites
      1:8, 0:8,                                %% Compression methods (null only)
      (byte_size(Extensions)):16, Extensions/binary>>.

build_server_hello(CipherSuite, PubKey, ServerRandom) ->
    SessionId = <<>>,

    Extensions = iolist_to_binary([
        %% Supported Versions (TLS 1.3)
        encode_extension(?TLS_EXT_SUPPORTED_VERSIONS,
                         <<16#03, 16#04>>),
        %% Key Share
        encode_extension(?TLS_EXT_KEY_SHARE,
                         <<(?TLS_X25519):16, (byte_size(PubKey)):16, PubKey/binary>>)
    ]),

    <<?TLS_1_2/binary,
      ServerRandom/binary,
      (byte_size(SessionId)):8, SessionId/binary,
      CipherSuite/binary,
      0:8,                                     %% Compression method (null)
      (byte_size(Extensions)):16, Extensions/binary>>.

build_encrypted_extensions(ALPN, Params) ->
    Extensions = iolist_to_binary([
        encode_alpn_extension_single(ALPN),
        encode_extension(?TLS_EXT_QUIC_TRANSPORT_PARAMS,
                         quic_transport_params:encode(Params))
    ]),
    <<(byte_size(Extensions)):16, Extensions/binary>>.

build_certificate(CertChain) ->
    %% Certificate context (empty for server)
    Context = <<>>,
    CertEntries = << <<(byte_size(Cert)):24, Cert/binary, 0:16>> || Cert <- CertChain >>,
    <<(byte_size(Context)):8, Context/binary,
      (byte_size(CertEntries)):24, CertEntries/binary>>.

build_certificate_verify(PrivKey, TranscriptHash, HashAlgo) ->
    %% Content to sign: 64 spaces + "TLS 1.3, server CertificateVerify" + 0 + hash
    Content = <<(binary:copy(<<16#20>>, 64))/binary,
                "TLS 1.3, server CertificateVerify", 0:8,
                TranscriptHash/binary>>,
    {SigAlgo, Signature} = sign(PrivKey, Content, HashAlgo),
    <<SigAlgo:16, (byte_size(Signature)):16, Signature/binary>>.

%% ===================================================================
%% TLS Message Parsing
%% ===================================================================

parse_server_hello(Bin) ->
    <<_LegacyVersion:2/binary, ServerRandom:32/binary,
      SessionIdLen:8, _SessionId:SessionIdLen/binary,
      CipherSuite:2/binary,
      _Compression:8,
      ExtLen:16, Extensions:ExtLen/binary>> = Bin,
    case parse_extensions(Extensions) of
        #{key_share := PeerPubKey} ->
            {ok, CipherSuite, PeerPubKey, ServerRandom};
        _ ->
            {error, missing_key_share}
    end.

parse_client_hello(Bin) ->
    <<_LegacyVersion:2/binary, ClientRandom:32/binary,
      SessionIdLen:8, _SessionId:SessionIdLen/binary,
      CSLen:16, _CipherSuites:CSLen/binary,
      CompLen:8, _Compressions:CompLen/binary,
      ExtLen:16, Extensions:ExtLen/binary>> = Bin,
    Exts = parse_extensions(Extensions),
    PeerPubKey = maps:get(key_share, Exts, undefined),
    ALPN = maps:get(alpn, Exts, []),
    TransportParams = maps:get(quic_transport_params, Exts, undefined),
    ServerName = maps:get(server_name, Exts, undefined),
    CipherSuite = ?TLS_AES_128_GCM_SHA256,  %% Default choice
    {ok, CipherSuite, PeerPubKey, ALPN, TransportParams, ClientRandom, ServerName}.

parse_encrypted_extensions(<<ExtLen:16, Extensions:ExtLen/binary>>) ->
    Exts = parse_extensions(Extensions),
    ALPN = case maps:get(alpn, Exts, []) of
        [A | _] -> A;
        _ -> undefined
    end,
    RemoteParams = maps:get(quic_transport_params, Exts, undefined),
    {ALPN, RemoteParams}.

parse_extensions(Bin) ->
    parse_extensions(Bin, #{}).

parse_extensions(<<>>, Acc) -> Acc;
parse_extensions(<<Type:16, Len:16, Value:Len/binary, Rest/binary>>, Acc) ->
    NewAcc = parse_extension(Type, Value, Acc),
    parse_extensions(Rest, NewAcc);
parse_extensions(_, Acc) -> Acc.

parse_extension(?TLS_EXT_SUPPORTED_VERSIONS, <<16#03, 16#04>>, Acc) ->
    Acc#{supported_versions => [tls_1_3]};
parse_extension(?TLS_EXT_SUPPORTED_VERSIONS, <<_Len:8, List/binary>>, Acc) ->
    Versions = [V || <<V:16>> <= List],
    Acc#{supported_versions => Versions};
parse_extension(?TLS_EXT_KEY_SHARE, Bin, Acc) ->
    %% Server key share: group(2) + key_len(2) + key
    case Bin of
        <<_Group:16, KLen:16, Key:KLen/binary, _/binary>> ->
            Acc#{key_share => Key};
        %% Client key share: entries_len(2) + entries...
        <<_EntriesLen:16, Entries/binary>> ->
            parse_key_share_entries(Entries, Acc);
        _ ->
            Acc
    end;
parse_extension(?TLS_EXT_ALPN, <<ListLen:16, List:ListLen/binary>>, Acc) ->
    Protocols = parse_alpn_list(List),
    Acc#{alpn => Protocols};
parse_extension(?TLS_EXT_QUIC_TRANSPORT_PARAMS, Value, Acc) ->
    case quic_transport_params:decode(Value) of
        {ok, Params} -> Acc#{quic_transport_params => Params};
        _ -> Acc
    end;
parse_extension(?TLS_EXT_SERVER_NAME, Value, Acc) ->
    %% Simple SNI parsing
    case Value of
        <<_ListLen:16, 0:8, NameLen:16, Name:NameLen/binary, _/binary>> ->
            Acc#{server_name => binary_to_list(Name)};
        _ ->
            Acc
    end;
parse_extension(_, _, Acc) -> Acc.

parse_key_share_entries(<<>>, Acc) -> Acc;
parse_key_share_entries(<<Group:16, KLen:16, Key:KLen/binary, Rest/binary>>, Acc) ->
    case Group of
        ?TLS_X25519 -> Acc#{key_share => Key};
        _ -> parse_key_share_entries(Rest, Acc)
    end;
parse_key_share_entries(_, Acc) -> Acc.

parse_alpn_list(<<>>) -> [];
parse_alpn_list(<<Len:8, Proto:Len/binary, Rest/binary>>) ->
    [Proto | parse_alpn_list(Rest)].

%% ===================================================================
%% Helpers
%% ===================================================================

encode_handshake(Type, Body) ->
    Len = byte_size(Body),
    <<Type:8, Len:24, Body/binary>>.

encode_extension(Type, Data) ->
    <<Type:16, (byte_size(Data)):16, Data/binary>>.

encode_alpn_extension(Protocols) ->
    ProtoList = << <<(byte_size(P)):8, P/binary>> || P <- Protocols >>,
    encode_extension(?TLS_EXT_ALPN,
                     <<(byte_size(ProtoList)):16, ProtoList/binary>>).

encode_alpn_extension_single(undefined) -> <<>>;
encode_alpn_extension_single(Proto) when is_binary(Proto) ->
    ProtoList = <<(byte_size(Proto)):8, Proto/binary>>,
    encode_extension(?TLS_EXT_ALPN,
                     <<(byte_size(ProtoList)):16, ProtoList/binary>>).

cipher_suite_info(?TLS_AES_128_GCM_SHA256) -> {sha256, 16};
cipher_suite_info(?TLS_AES_256_GCM_SHA384) -> {sha384, 32};
cipher_suite_info(?TLS_CHACHA20_POLY1305_SHA256) -> {sha256, 32};
cipher_suite_info(_) -> {sha256, 16}.

hash_length(sha256) -> 32;
hash_length(sha384) -> 48.

derive_secret(Secret, Label, ContextHash, HashAlgo) when is_binary(ContextHash) ->
    quic_crypto:hkdf_expand_label(Secret, Label, ContextHash,
                                   hash_length(HashAlgo), HashAlgo, <<"tls13 ">>);
derive_secret(Secret, Label, <<>>, HashAlgo) ->
    EmptyHash = crypto:hash(HashAlgo, <<>>),
    quic_crypto:hkdf_expand_label(Secret, Label, EmptyHash,
                                   hash_length(HashAlgo), HashAlgo, <<"tls13 ">>).

negotiate_alpn(ClientALPN, ServerALPN) ->
    %% Pick the first client protocol that the server supports
    case [P || P <- ClientALPN, lists:member(P, ServerALPN)] of
        [First | _] -> First;
        [] -> undefined
    end.

load_cert_and_key(CertFile, KeyFile) ->
    try
        {ok, CertPem} = file:read_file(CertFile),
        CertEntries = public_key:pem_decode(CertPem),
        CertChain = [Der || {'Certificate', Der, _} <- CertEntries],

        {ok, KeyPem} = file:read_file(KeyFile),
        [KeyEntry | _] = public_key:pem_decode(KeyPem),
        PrivKey = public_key:pem_entry_decode(KeyEntry),

        {ok, CertChain, PrivKey}
    catch
        _:Reason ->
            {error, {cert_load_failed, Reason}}
    end.

sign(PrivKey, Content, _HashAlgo) ->
    case PrivKey of
        #'ECPrivateKey'{} ->
            Sig = public_key:sign(Content, sha256, PrivKey),
            {?TLS_ECDSA_SECP256R1_SHA256, Sig};
        #'RSAPrivateKey'{} ->
            Sig = public_key:sign(Content, sha256, PrivKey,
                                  [{rsa_padding, rsa_pkcs1_pss_padding},
                                   {rsa_pss_saltlen, -1},
                                   {rsa_mgf1_md, sha256}]),
            {?TLS_RSA_PSS_RSAE_SHA256, Sig};
        _ ->
            %% Try RSA-PSS by default
            Sig = public_key:sign(Content, sha256, PrivKey),
            {?TLS_RSA_PSS_RSAE_SHA256, Sig}
    end.
