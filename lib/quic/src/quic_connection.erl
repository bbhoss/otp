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

%% QUIC Connection State Machine (RFC 9000)
%%
%% Each QUIC connection is managed by a gen_statem process.
%% States: idle -> handshake -> established -> closing -> draining -> closed

-module(quic_connection).

-behaviour(gen_statem).

-include("quic.hrl").

%% API
-export([
    start_link/1,
    connect/4,
    accept_init/4,
    open_stream/2,
    accept_stream/2,
    send/3,
    recv/4,
    send_datagram/2,
    recv_datagram/2,
    close/2,
    close_stream/2,
    handle_packet/2,
    connection_info/1,
    controlling_process/2
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    idle/3,
    handshake/3,
    established/3,
    closing/3,
    draining/3,
    terminate/3
]).

%% Internal state
-record(conn_data, {
    role                :: client | server,
    owner               :: pid(),
    owner_mon           :: reference(),
    udp_socket          :: term() | undefined,
    peer_addr           :: term() | undefined,
    local_addr          :: term() | undefined,
    dcid                :: binary(),
    scid                :: binary(),
    original_dcid       :: binary(),
    %% Crypto keys per level
    initial_keys        :: map() | undefined,
    handshake_keys      :: map() | undefined,
    app_keys            :: map() | undefined,
    %% TLS state
    tls_state           :: term() | undefined,
    %% Streams
    streams = #{}       :: #{non_neg_integer() => #quic_stream{}},
    next_bidi_stream    :: non_neg_integer(),
    next_uni_stream     :: non_neg_integer(),
    %% Flow control
    max_data_local = 1048576   :: non_neg_integer(),
    max_data_remote = 0        :: non_neg_integer(),
    data_sent = 0              :: non_neg_integer(),
    data_recvd = 0             :: non_neg_integer(),
    %% Packet number spaces
    pn_spaces = #{
        initial => #pn_space{},
        handshake => #pn_space{},
        application => #pn_space{}
    } :: map(),
    %% Recovery
    recovery            :: #recovery{},
    %% Transport params
    local_params        :: #transport_params{},
    remote_params       :: #transport_params{} | undefined,
    %% Active mode
    active = false      :: true | false | once | integer(),
    mode = binary       :: binary | list,
    %% Waiters
    stream_acceptors = [] :: [{pid(), reference()}],
    conn_waiters = []     :: [{pid(), reference()}],
    datagram_queue = []   :: [binary()],
    datagram_waiters = [] :: [{pid(), reference()}],
    %% Options
    alpn                :: [binary()],
    verify = verify_none :: verify_peer | verify_none,
    certfile            :: string() | undefined,
    keyfile             :: string() | undefined,
    %% Idle timeout
    idle_timeout = 30000 :: non_neg_integer(),
    %% PTO timer
    pto_timer           :: reference() | undefined,
    %% Handshake complete flag (set when TLS handshake_complete action received)
    handshake_done = false :: boolean(),
    %% Key update state (RFC 9001 Section 6)
    key_phase = 0          :: 0 | 1,
    client_app_secret      :: binary() | undefined,
    server_app_secret      :: binary() | undefined
}).

%% ===================================================================
%% API
%% ===================================================================

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

connect(Pid, Host, Port, Timeout) ->
    gen_statem:call(Pid, {connect, Host, Port}, Timeout).

accept_init(Pid, Socket, PeerAddr, InitialPacket) ->
    gen_statem:call(Pid, {accept_init, Socket, PeerAddr, InitialPacket}, 5000).

open_stream(Pid, Opts) ->
    gen_statem:call(Pid, {open_stream, Opts}).

accept_stream(Pid, Timeout) ->
    gen_statem:call(Pid, accept_stream, Timeout).

send(Pid, StreamId, Data) ->
    gen_statem:call(Pid, {send, StreamId, Data}).

recv(Pid, StreamId, Length, Timeout) ->
    gen_statem:call(Pid, {recv, StreamId, Length}, Timeout).

send_datagram(Pid, Data) ->
    gen_statem:call(Pid, {send_datagram, Data}).

recv_datagram(Pid, Timeout) ->
    gen_statem:call(Pid, recv_datagram, Timeout).

close(Pid, ErrorCode) ->
    gen_statem:call(Pid, {close, ErrorCode}, 5000).

close_stream(Pid, StreamId) ->
    gen_statem:call(Pid, {close_stream, StreamId}).

handle_packet(Pid, {Data, PeerAddr}) ->
    gen_statem:cast(Pid, {packet, Data, PeerAddr}).

connection_info(Pid) ->
    gen_statem:call(Pid, connection_info).

controlling_process(Pid, NewOwner) ->
    gen_statem:call(Pid, {controlling_process, NewOwner}).

%% ===================================================================
%% gen_statem Callbacks
%% ===================================================================

callback_mode() -> state_functions.

init(#{role := Role, owner := Owner, options := Opts}) ->
    MonRef = erlang:monitor(process, Owner),
    SCID = crypto:strong_rand_bytes(8),

    %% Parse options
    ALPN = proplists:get_value(alpn, Opts, []),
    Active = proplists:get_value(active, Opts, false),
    Mode = case lists:member(binary, Opts) of true -> binary; _ ->
               case lists:member(list, Opts) of true -> list; _ -> binary end end,
    Verify = proplists:get_value(verify, Opts, verify_none),
    CertFile = proplists:get_value(certfile, Opts, undefined),
    KeyFile = proplists:get_value(keyfile, Opts, undefined),
    IdleTimeout = proplists:get_value(max_idle_timeout, Opts, 30000),

    LocalParams = build_local_params(Opts, SCID),

    {NextBidi, NextUni} = case Role of
        client -> {0, 2};
        server -> {1, 3}
    end,

    Data = #conn_data{
        role = Role,
        owner = Owner,
        owner_mon = MonRef,
        scid = SCID,
        dcid = <<>>,
        original_dcid = <<>>,
        next_bidi_stream = NextBidi,
        next_uni_stream = NextUni,
        recovery = quic_recovery:init(),
        local_params = LocalParams,
        active = Active,
        mode = Mode,
        alpn = ALPN,
        verify = Verify,
        certfile = CertFile,
        keyfile = KeyFile,
        idle_timeout = IdleTimeout
    },
    {ok, idle, Data}.

%% ===================================================================
%% State: idle
%% ===================================================================

idle({call, From}, {connect, Host, Port}, Data) ->
    %% Client initiating connection
    DCID = crypto:strong_rand_bytes(8),

    %% Open UDP socket
    case socket:open(inet, dgram, udp) of
        {ok, Socket} ->
            ok = socket:bind(Socket, #{family => inet, addr => any, port => 0}),
            {ok, LocalAddr} = socket:sockname(Socket),
            PeerAddr = #{family => inet, addr => resolve_host(Host), port => Port},

            %% Derive initial keys
            InitialKeys = quic_crypto:derive_initial_keys(DCID),

            %% Initialize TLS
            {ok, TLSState0} = quic_tls:init_client(Data#conn_data.alpn,
                                                     Data#conn_data.local_params),
            {CHBin, TLSState} = quic_tls:get_client_hello(TLSState0),

            %% Build Initial packet with ClientHello in CRYPTO frame
            CryptoFrame = quic_frame:encode({crypto, 0, CHBin}),
            PaddingLen = max(0, 1200 - 100 - byte_size(CryptoFrame)),
            Payload = <<CryptoFrame/binary, 0:PaddingLen/unit:8>>,

            #{client := ClientKeys} = InitialKeys,
            Packet = quic_packet:encode_initial(DCID, Data#conn_data.scid,
                                                 <<>>, 0, Payload),
            PaddedPacket = quic_packet:pad_initial(Packet, 1200),

            %% Protect the packet
            ProtectedPacket = protect_initial_packet(PaddedPacket, 0, ClientKeys),

            %% Send
            io:format("[conn:~p] client sending Initial, ~p bytes to ~p~n",
                      [self(), byte_size(ProtectedPacket), PeerAddr]),
            SendResult = socket:sendto(Socket, ProtectedPacket, PeerAddr),
            io:format("[conn:~p] sendto result: ~p~n", [self(), SendResult]),

            %% Start receiving
            start_recv(Socket),

            %% Update PN space
            PNSpaces = Data#conn_data.pn_spaces,
            InitPN = maps:get(initial, PNSpaces),
            NewPNSpaces = PNSpaces#{initial => InitPN#pn_space{next_pn = 1}},

            Data2 = Data#conn_data{
                dcid = DCID,
                original_dcid = DCID,
                udp_socket = Socket,
                peer_addr = PeerAddr,
                local_addr = LocalAddr,
                initial_keys = InitialKeys,
                tls_state = TLSState,
                pn_spaces = NewPNSpaces,
                conn_waiters = [{From, undefined}]
            },

            %% Set PTO timer
            PTO = quic_recovery:get_pto(Data2#conn_data.recovery),
            PTOTimer = erlang:send_after(round(PTO), self(), pto_timeout),

            {next_state, handshake, Data2#conn_data{pto_timer = PTOTimer}};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;

idle({call, From}, {accept_init, Socket, PeerAddr, PacketData}, Data) ->
    %% Server receiving initial packet — set socket/peer first so TLS can send
    io:format("[conn:~p] accept_init, pkt=~p bytes~n", [self(), byte_size(PacketData)]),
    Data1 = Data#conn_data{udp_socket = Socket, peer_addr = PeerAddr},
    case process_initial_packet(PacketData, Data1) of
        {ok, Data2} ->
            io:format("[conn:~p] initial processed OK, app_keys=~p~n",
                      [self(), Data2#conn_data.app_keys =/= undefined]),
            SCID = Data2#conn_data.scid,
            {next_state, handshake, Data2, [{reply, From, {ok, SCID}}]};
        {error, Reason} ->
            io:format("[conn:~p] initial FAILED: ~p~n", [self(), Reason]),
            gen_statem:reply(From, {error, Reason}),
            {stop, normal}
    end;

idle(info, Msg, Data) ->
    handle_common_info(Msg, idle, Data).

%% ===================================================================
%% State: handshake
%% ===================================================================

handshake(cast, {packet, PacketData, _PeerAddr}, Data) ->
    case process_received_packet(PacketData, Data) of
        {ok, Data2} ->
            %% If handshake just completed, send ACK for client's Handshake
            Data3 = case Data2#conn_data.handshake_done of
                true -> send_handshake_ack(Data2);
                false -> Data2
            end,
            maybe_transition_to_established(Data3);
        {error, Reason} ->
            io:format("[conn:~p] handshake packet FAILED: ~p~n", [self(), Reason]),
            {keep_state, Data}
    end;

handshake(info, {'$socket', Socket, select, _SelectRef}, #conn_data{udp_socket = Socket} = Data) ->
    handshake_drain(Socket, Data);

handshake(info, {handshake_drain, Socket}, #conn_data{udp_socket = Socket} = Data) ->
    handshake_drain(Socket, Data);

handshake(info, pto_timeout, Data) ->
    %% PTO fired during handshake - retransmit
    %% For now, just reset the timer
    PTO = quic_recovery:get_pto(Data#conn_data.recovery),
    NewRecovery = Data#conn_data.recovery#recovery{
        pto_count = Data#conn_data.recovery#recovery.pto_count + 1
    },
    PTOTimer = erlang:send_after(round(PTO * 2), self(), pto_timeout),
    {keep_state, Data#conn_data{recovery = NewRecovery, pto_timer = PTOTimer}};

handshake({call, From}, {send, _StreamId, _Data}, _Data2) ->
    {keep_state_and_data, [{reply, From, {error, not_established}}]};

handshake({call, From}, accept_stream, Data) ->
    %% Queue the acceptor
    Data2 = Data#conn_data{
        stream_acceptors = Data#conn_data.stream_acceptors ++ [{From, undefined}]
    },
    {keep_state, Data2};

handshake({call, From}, {controlling_process, NewOwner}, Data) ->
    erlang:demonitor(Data#conn_data.owner_mon, [flush]),
    MonRef = erlang:monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = MonRef},
     [{reply, From, ok}]};

handshake(info, Msg, Data) ->
    handle_common_info(Msg, handshake, Data).

%% ===================================================================
%% State: established
%% ===================================================================

established({call, From}, {open_stream, Opts}, Data) ->
    Type = case lists:member(unidirectional, Opts) of
        true -> unidirectional;
        false -> bidirectional
    end,
    {StreamId, Data2} = allocate_stream_id(Type, Data),
    MaxSend = case Type of
        bidirectional ->
            case Data2#conn_data.remote_params of
                #transport_params{initial_max_stream_data_bidi_remote = V} -> V;
                _ -> 0
            end;
        unidirectional ->
            case Data2#conn_data.remote_params of
                #transport_params{initial_max_stream_data_uni = V} -> V;
                _ -> 0
            end
    end,
    MaxRecv = case Type of
        bidirectional ->
            Data2#conn_data.local_params#transport_params.initial_max_stream_data_bidi_local;
        unidirectional -> 0
    end,
    Stream = quic_stream:new(StreamId, MaxSend, MaxRecv),
    Streams = maps:put(StreamId, Stream, Data2#conn_data.streams),
    StreamRef = {quic_stream, self(), StreamId},
    {keep_state, Data2#conn_data{streams = Streams},
     [{reply, From, {ok, StreamRef}}]};

established({call, From}, accept_stream, Data) ->
    Data2 = Data#conn_data{
        stream_acceptors = Data#conn_data.stream_acceptors ++ [{From, undefined}]
    },
    {keep_state, Data2};

established({call, From}, {send, StreamId, SendData}, Data) ->
    case maps:find(StreamId, Data#conn_data.streams) of
        {ok, Stream} ->
            case quic_stream:send(Stream, SendData) of
                {ok, Frames, NewStream} ->
                    Streams = maps:put(StreamId, NewStream, Data#conn_data.streams),
                    Data2 = Data#conn_data{streams = Streams},
                    %% Send frames
                    Data3 = send_stream_frames(Frames, Data2),
                    {keep_state, Data3, [{reply, From, ok}]};
                {error, _} = Error ->
                    {keep_state_and_data, [{reply, From, Error}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end;

established({call, From}, {recv, StreamId, Length}, Data) ->
    case maps:find(StreamId, Data#conn_data.streams) of
        {ok, Stream} ->
            {ReadData, NewStream} = quic_stream:read(Stream, Length),
            Streams = maps:put(StreamId, NewStream, Data#conn_data.streams),
            case byte_size(ReadData) > 0 of
                true ->
                    {keep_state, Data#conn_data{streams = Streams},
                     [{reply, From, {ok, ReadData}}]};
                false ->
                    case NewStream#quic_stream.fin_received of
                        true ->
                            {keep_state, Data#conn_data{streams = Streams},
                             [{reply, From, {error, closed}}]};
                        false ->
                            %% No data available - add waiter
                            WStream = quic_stream:add_recv_waiter(NewStream,
                                                                   {From, Length}),
                            Streams2 = maps:put(StreamId, WStream, Data#conn_data.streams),
                            {keep_state, Data#conn_data{streams = Streams2}}
                    end
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end;

established({call, From}, {close_stream, StreamId}, Data) ->
    case maps:find(StreamId, Data#conn_data.streams) of
        {ok, Stream} ->
            {FinFrame, NewStream} = quic_stream:close_send(Stream),
            Streams = maps:put(StreamId, NewStream, Data#conn_data.streams),
            Data2 = Data#conn_data{streams = Streams},
            Data3 = send_stream_frames([FinFrame], Data2),
            {keep_state, Data3, [{reply, From, ok}]};
        error ->
            {keep_state_and_data, [{reply, From, ok}]}
    end;

established({call, From}, {send_datagram, DGData}, Data) ->
    Frame = quic_frame:encode({datagram, DGData}),
    Data2 = send_app_data(Frame, Data),
    {keep_state, Data2, [{reply, From, ok}]};

established({call, From}, recv_datagram, Data) ->
    case Data#conn_data.datagram_queue of
        [DG | Rest] ->
            {keep_state, Data#conn_data{datagram_queue = Rest},
             [{reply, From, {ok, DG}}]};
        [] ->
            Data2 = Data#conn_data{
                datagram_waiters = Data#conn_data.datagram_waiters ++ [{From, undefined}]
            },
            {keep_state, Data2}
    end;

established({call, From}, {close, ErrorCode}, Data) ->
    %% Send CONNECTION_CLOSE
    CloseFrame = quic_frame:encode({connection_close, ErrorCode, 0, <<>>}),
    Data2 = send_app_data(CloseFrame, Data),
    %% Notify owner
    Data2#conn_data.owner ! {quic_closed, self()},
    {next_state, closing, Data2, [{reply, From, ok}]};

established({call, From}, connection_info, Data) ->
    Info = #{
        alpn => Data#conn_data.alpn,
        peer_addr => Data#conn_data.peer_addr,
        local_addr => Data#conn_data.local_addr,
        dcid => Data#conn_data.dcid,
        scid => Data#conn_data.scid
    },
    {keep_state_and_data, [{reply, From, {ok, Info}}]};

established({call, From}, {controlling_process, NewOwner}, Data) ->
    erlang:demonitor(Data#conn_data.owner_mon, [flush]),
    MonRef = erlang:monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = MonRef},
     [{reply, From, ok}]};

established(cast, {packet, PacketData, _PeerAddr}, Data) ->
    case process_received_packet(PacketData, Data) of
        {ok, Data2} ->
            {keep_state, Data2, [idle_timeout_action(Data2)]};
        {error, _} -> {keep_state, Data}
    end;

established(info, {'$socket', Socket, select, _Ref},
            #conn_data{udp_socket = Socket} = Data) ->
    case socket:recvfrom(Socket, 0, [], nowait) of
        {ok, {_Source, PacketData}} ->
            start_recv(Socket),
            case process_received_packet(PacketData, Data) of
                {ok, Data2} ->
                    {keep_state, Data2, [idle_timeout_action(Data2)]};
                {error, _} -> {keep_state, Data}
            end;
        {select, _} ->
            {keep_state, Data};
        {error, _} ->
            {keep_state, Data}
    end;

established(info, {quic_data_available, StreamId}, Data) ->
    %% Stream has data - check for waiters
    case maps:find(StreamId, Data#conn_data.streams) of
        {ok, #quic_stream{recv_waiters = [{From, Length} | RestW]} = Stream} ->
            {ReadData, NewStream0} = quic_stream:read(Stream, Length),
            NewStream = NewStream0#quic_stream{recv_waiters = RestW},
            Streams = maps:put(StreamId, NewStream, Data#conn_data.streams),
            case byte_size(ReadData) > 0 of
                true ->
                    gen_statem:reply(From, {ok, ReadData}),
                    {keep_state, Data#conn_data{streams = Streams}};
                false ->
                    {keep_state, Data#conn_data{streams = Streams}}
            end;
        _ ->
            {keep_state, Data}
    end;

established(info, pto_timeout, Data) ->
    %% PTO timeout - send a PING
    PingFrame = quic_frame:encode(ping),
    Data2 = send_app_data(PingFrame, Data),
    PTO = quic_recovery:get_pto(Data2#conn_data.recovery),
    NewRecovery = Data2#conn_data.recovery#recovery{
        pto_count = Data2#conn_data.recovery#recovery.pto_count + 1
    },
    PTOTimer = erlang:send_after(round(PTO), self(), pto_timeout),
    {keep_state, Data2#conn_data{recovery = NewRecovery, pto_timer = PTOTimer}};

established({timeout, idle}, idle_timeout, Data) ->
    Data#conn_data.owner ! {quic_closed, self()},
    {next_state, draining, Data};

established(info, keepalive, Data) ->
    PingFrame = quic_frame:encode(ping),
    Data2 = send_app_data(PingFrame, Data),
    start_keepalive_timer(Data2#conn_data.idle_timeout),
    {keep_state, Data2};

established(info, Msg, Data) ->
    handle_common_info(Msg, established, Data).

%% ===================================================================
%% State: closing
%% ===================================================================

closing(info, {'$socket', Socket, select, _Ref},
        #conn_data{udp_socket = Socket} = Data) ->
    %% Drain remaining packets
    socket:recvfrom(Socket, 0, [], nowait),
    start_recv(Socket),
    {keep_state, Data};

closing({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closing}}]};

closing(info, _Msg, Data) ->
    %% After 3x PTO, transition to closed
    PTO = quic_recovery:get_pto(Data#conn_data.recovery),
    erlang:send_after(round(3 * PTO), self(), drain_complete),
    {next_state, draining, Data}.

%% ===================================================================
%% State: draining
%% ===================================================================

draining(info, drain_complete, _Data) ->
    {stop, normal};

draining({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closed}}]};

draining(cast, _, _Data) ->
    keep_state_and_data;

draining(info, _, _Data) ->
    keep_state_and_data.

%% ===================================================================
%% Terminate
%% ===================================================================

terminate(_Reason, _State, #conn_data{role = client, udp_socket = Socket}) ->
    case Socket of
        undefined -> ok;
        _ -> socket:close(Socket)
    end,
    ok;
terminate(_Reason, _State, #conn_data{role = server}) ->
    ok.

%% ===================================================================
%% Packet Processing
%% ===================================================================

process_initial_packet(PacketData, Data) ->
    %% Parse the unprotected parts of the Initial packet to get DCID
    case quic_packet:decode_header(PacketData) of
        {ok, #quic_packet{type = initial, dcid = DCID, scid = PeerSCID} = _Pkt, _Rest} ->
            io:format("[conn:~p] Initial: DCID=~p, PeerSCID=~p~n",
                      [self(), DCID, PeerSCID]),
            %% Derive initial keys from client's DCID
            InitialKeys = quic_crypto:derive_initial_keys(DCID),

            %% Unprotect the packet
            #{client := ClientKeys} = InitialKeys,
            case quic_crypto:unprotect_packet(PacketData, 0, ClientKeys, true) of
                {ok, _Header, Payload, _PN} ->
                    %% Decode frames
                    case quic_frame:decode_all(Payload) of
                        {ok, Frames} ->
                            %% Process CRYPTO frames for TLS
                            CryptoData = extract_crypto_data(Frames),
                            case byte_size(CryptoData) > 0 of
                                true ->
                                    process_server_initial(DCID, PeerSCID, CryptoData,
                                                           InitialKeys, Data);
                                false ->
                                    {error, no_crypto_data}
                            end;
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        _ ->
            {error, invalid_initial_packet}
    end.

process_server_initial(OrigDCID, PeerSCID, CryptoData, InitialKeys, Data) ->
    %% Set local transport params with original DCID
    LocalParams = (Data#conn_data.local_params)#transport_params{
        original_destination_connection_id = OrigDCID,
        initial_source_connection_id = Data#conn_data.scid
    },

    %% Initialize TLS server with local params
    {ok, TLSState0} = quic_tls:init_server(
        Data#conn_data.certfile, Data#conn_data.keyfile, Data#conn_data.alpn,
        LocalParams),

    case quic_tls:handle_crypto_data(CryptoData, initial, TLSState0) of
        {ok, Actions, TLSState} ->
            %% Update crypto_offset for initial pn_space to prevent reprocessing
            PNSpaces0 = Data#conn_data.pn_spaces,
            InitialPN = maps:get(initial, PNSpaces0),
            InitialPN2 = InitialPN#pn_space{crypto_offset = byte_size(CryptoData)},
            PNSpaces1 = PNSpaces0#{initial => InitialPN2},
            Data2 = Data#conn_data{
                dcid = PeerSCID,
                original_dcid = OrigDCID,
                initial_keys = InitialKeys,
                tls_state = TLSState,
                local_params = LocalParams,
                pn_spaces = PNSpaces1
            },
            Data3 = process_tls_actions(Actions, Data2),
            {ok, Data3};
        {error, _} = Err ->
            Err
    end.

process_received_packet(PacketData, Data) ->
    %% Determine packet type from first byte
    case PacketData of
        <<1:1, _:7, _/binary>> ->
            %% Long header
            process_long_header_packet(PacketData, Data);
        <<0:1, _:7, _/binary>> ->
            %% Short header (1-RTT)
            process_short_header_packet(PacketData, Data);
        _ ->
            {error, invalid_packet}
    end.

process_long_header_packet(PacketData, Data) ->
    %% Peek at the type
    <<_FB:8, _Version:32, DCIDLen:8, _DCID:DCIDLen/binary,
      SCIDLen:8, _SCID:SCIDLen/binary, _/binary>> = PacketData,
    <<FB:8, _/binary>> = PacketData,
    Type = (FB band 16#30) bsr 4,

    case Type of
        ?INITIAL_PACKET ->
            %% Initial packet
            #{client := ClientKeys, server := _ServerKeys} = Data#conn_data.initial_keys,
            Keys = case Data#conn_data.role of
                server -> ClientKeys;
                client ->
                    #{server := SK} = Data#conn_data.initial_keys,
                    SK
            end,
            case quic_crypto:unprotect_packet(PacketData, 0, Keys, true) of
                {ok, _Header, Payload, _PN} ->
                    case quic_frame:decode_all(Payload) of
                        {ok, Frames} ->
                            process_frames(Frames, initial, Data);
                        {error, _} = Err -> Err
                    end;
                {error, _} = Err -> Err
            end;
        ?HANDSHAKE_PACKET ->
            case Data#conn_data.handshake_keys of
                undefined ->
                    {error, no_handshake_keys};
                HSKeys ->
                    Keys = case Data#conn_data.role of
                        client ->
                            maps:get(server, HSKeys);
                        server ->
                            maps:get(client, HSKeys)
                    end,
                    case quic_crypto:unprotect_packet(PacketData, 0, Keys, true) of
                        {ok, _Header, Payload, _PN} ->
                            case quic_frame:decode_all(Payload) of
                                {ok, Frames} ->
                                    process_frames(Frames, handshake, Data);
                                {error, _} = Err -> Err
                            end;
                        {error, _} = Err ->
                            io:format("[conn:~p] HS decrypt FAILED: ~p~n", [self(), Err]),
                            Err
                    end
            end;
        _ ->
            {error, {unsupported_packet_type, Type}}
    end.

process_short_header_packet(PacketData, Data) ->
    case Data#conn_data.app_keys of
        undefined ->
            {error, no_app_keys};
        AppKeys ->
            Keys = case Data#conn_data.role of
                client -> maps:get(server, AppKeys);
                server -> maps:get(client, AppKeys)
            end,
            DCIDLen = byte_size(Data#conn_data.scid),
            PNSpaces = Data#conn_data.pn_spaces,
            AppPNSpace = maps:get(application, PNSpaces),
            LargestRecv = max(0, AppPNSpace#pn_space.largest_received),
            case quic_crypto:unprotect_packet(PacketData, LargestRecv, Keys, false, DCIDLen) of
                {ok, _Header, Payload, PN} ->
                    process_decrypted_1rtt(Payload, PN, AppPNSpace, PNSpaces, Data);
                {error, {decrypt_failed, #{unprot_fb := FirstByte}}} ->
                    PktKeyPhase = (FirstByte bsr 2) band 1,
                    case PktKeyPhase =/= Data#conn_data.key_phase of
                        true ->
                            try_key_update(PacketData, Keys, DCIDLen, LargestRecv,
                                           AppPNSpace, PNSpaces, Data);
                        false ->
                            {error, decrypt_failed}
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

try_key_update(PacketData, OldPeerKeys, DCIDLen, LargestRecv,
               AppPNSpace, PNSpaces, Data) ->
    PeerSecret = case Data#conn_data.role of
        client -> Data#conn_data.server_app_secret;
        server -> Data#conn_data.client_app_secret
    end,
    OwnSecret = case Data#conn_data.role of
        client -> Data#conn_data.client_app_secret;
        server -> Data#conn_data.server_app_secret
    end,
    case PeerSecret of
        undefined ->
            {error, no_traffic_secret_for_key_update};
        _ ->
            {_OldKey, _OldIV, HPKey} = OldPeerKeys,
            {NewPeerSecret, {NewKey, NewIV}} =
                quic_crypto:next_key_update(PeerSecret, sha256, 16),
            NewPeerKeys = {NewKey, NewIV, HPKey},
            case quic_crypto:unprotect_packet(PacketData, LargestRecv,
                                              NewPeerKeys, false, DCIDLen) of
                {ok, _Header, Payload, PN} ->
                    io:format("[conn:~p] key update at PN=~p~n", [self(), PN]),
                    {NewOwnSecret, {NewOwnKey, NewOwnIV}} =
                        quic_crypto:next_key_update(OwnSecret, sha256, 16),
                    OldAppKeys = Data#conn_data.app_keys,
                    {_, _, OwnHPKey} = case Data#conn_data.role of
                        client -> maps:get(client, OldAppKeys);
                        server -> maps:get(server, OldAppKeys)
                    end,
                    NewAppKeys = case Data#conn_data.role of
                        client ->
                            #{client => {NewOwnKey, NewOwnIV, OwnHPKey},
                              server => NewPeerKeys};
                        server ->
                            #{client => NewPeerKeys,
                              server => {NewOwnKey, NewOwnIV, OwnHPKey}}
                    end,
                    {NewClientSecret, NewServerSecret} = case Data#conn_data.role of
                        client -> {NewOwnSecret, NewPeerSecret};
                        server -> {NewPeerSecret, NewOwnSecret}
                    end,
                    Data1 = Data#conn_data{
                        app_keys = NewAppKeys,
                        key_phase = 1 - Data#conn_data.key_phase,
                        client_app_secret = NewClientSecret,
                        server_app_secret = NewServerSecret
                    },
                    process_decrypted_1rtt(Payload, PN, AppPNSpace, PNSpaces, Data1);
                {error, _} ->
                    {error, decrypt_failed}
            end
    end.

process_decrypted_1rtt(Payload, PN, AppPNSpace, PNSpaces, Data) ->
    RecvPNs = lists:usort([PN | AppPNSpace#pn_space.received_pns]),
    NewAppPNSpace = AppPNSpace#pn_space{
        largest_received = max(PN, AppPNSpace#pn_space.largest_received),
        received_pns = RecvPNs
    },
    NewPNSpaces = PNSpaces#{application => NewAppPNSpace},
    Data1 = Data#conn_data{pn_spaces = NewPNSpaces},
    case quic_frame:decode_all(Payload) of
        {ok, Frames} ->
            case process_frames(Frames, application, Data1) of
                {ok, Data2} ->
                    Data3 = send_app_ack(PN, Data2),
                    {ok, Data3};
                {error, _} = Err2 ->
                    Err2
            end;
        {error, _} = Err ->
            Err
    end.

process_frames([], _Level, Data) ->
    {ok, Data};
process_frames([Frame | Rest], Level, Data) ->
    case process_frame(Frame, Level, Data) of
        {ok, Data2} ->
            process_frames(Rest, Level, Data2);
        {error, _} = Err ->
            Err
    end.

process_frame(padding, _Level, Data) ->
    {ok, Data};

process_frame(ping, _Level, Data) ->
    %% ACK-eliciting, but no action needed
    {ok, Data};

process_frame({ack, LargestAcked, AckDelay, _Ranges}, Level, Data) ->
    PNSpace = level_to_pn_space(Level),
    {_LostPNs, NewRecovery} = quic_recovery:on_ack_received(
        LargestAcked, AckDelay, PNSpace, Data#conn_data.recovery),
    {ok, Data#conn_data{recovery = NewRecovery}};

process_frame({crypto, Offset, CryptoData}, Level, Data) ->
    %% Buffer the crypto data and process via TLS
    PNSpace = level_to_pn_space(Level),
    PNSpaces = Data#conn_data.pn_spaces,
    PN = maps:get(PNSpace, PNSpaces),
    EndOffset = Offset + byte_size(CryptoData),
    %% Skip already-processed crypto data (handles retransmissions)
    case EndOffset =< PN#pn_space.crypto_offset of
        true ->
            {ok, Data};
        false ->
            ExistingBuf = PN#pn_space.crypto_buffer,
            %% Trim any overlap with already-processed data
            NewData = case Offset < PN#pn_space.crypto_offset of
                true ->
                    Skip = PN#pn_space.crypto_offset - Offset,
                    <<_:Skip/binary, Rest/binary>> = CryptoData,
                    Rest;
                false ->
                    CryptoData
            end,
            NewBuf = <<ExistingBuf/binary, NewData/binary>>,
            NewPN = PN#pn_space{crypto_buffer = NewBuf, crypto_offset = EndOffset},
            NewPNSpaces = PNSpaces#{PNSpace => NewPN},
            Data2 = Data#conn_data{pn_spaces = NewPNSpaces},

            %% Process accumulated crypto data through TLS
            case quic_tls:handle_crypto_data(NewBuf, Level, Data2#conn_data.tls_state) of
                {ok, Actions, TLSState} ->
                    %% Clear the buffer
                    ClearedPN = NewPN#pn_space{crypto_buffer = <<>>},
                    Data3 = Data2#conn_data{
                        tls_state = TLSState,
                        pn_spaces = (Data2#conn_data.pn_spaces)#{PNSpace => ClearedPN}
                    },
                    Data4 = process_tls_actions(Actions, Data3),
                    {ok, Data4};
                {error, _} = Err ->
                    Err
            end
    end;

process_frame({stream, StreamId, Offset, StreamData, Fin}, _Level, Data) ->
    %% Get or create stream
    {Stream, Data2} = get_or_create_stream(StreamId, Data),
    case quic_stream:receive_data(Stream, StreamData, Offset, Fin) of
        {ok, NewStream} ->
            %% Notify waiters or deliver in active mode
            NewStream2 = maybe_deliver_stream_data(StreamId, NewStream, Data2),
            Streams = maps:put(StreamId, NewStream2, Data2#conn_data.streams),
            {ok, Data2#conn_data{streams = Streams}};
        {error, _} = Err ->
            Err
    end;

process_frame({max_data, MaxData}, _Level, Data) ->
    {ok, Data#conn_data{max_data_remote = MaxData}};

process_frame({max_stream_data, StreamId, MaxStreamData}, _Level, Data) ->
    case maps:find(StreamId, Data#conn_data.streams) of
        {ok, Stream} ->
            NewStream = Stream#quic_stream{max_send_data = MaxStreamData},
            Streams = maps:put(StreamId, NewStream, Data#conn_data.streams),
            {ok, Data#conn_data{streams = Streams}};
        error ->
            {ok, Data}
    end;

process_frame({max_streams, bidi, MaxStreams}, _Level, Data) ->
    {ok, Data};

process_frame({max_streams, uni, MaxStreams}, _Level, Data) ->
    {ok, Data};

process_frame({connection_close, ErrorCode, _FrameType, Reason}, _Level, Data) ->
    Data#conn_data.owner ! {quic_error, self(), {connection_close, ErrorCode, Reason}},
    Data#conn_data.owner ! {quic_closed, self()},
    {ok, Data};

process_frame({connection_close_app, ErrorCode, Reason}, _Level, Data) ->
    Data#conn_data.owner ! {quic_error, self(), {app_close, ErrorCode, Reason}},
    Data#conn_data.owner ! {quic_closed, self()},
    {ok, Data};

process_frame(handshake_done, _Level, Data) ->
    %% Client receives HANDSHAKE_DONE from server
    {ok, Data};

process_frame({datagram, DGData}, _Level, Data) ->
    case Data#conn_data.datagram_waiters of
        [{From, _} | Rest] ->
            gen_statem:reply(From, {ok, DGData}),
            {ok, Data#conn_data{datagram_waiters = Rest}};
        [] ->
            case Data#conn_data.active of
                false ->
                    Queue = Data#conn_data.datagram_queue ++ [DGData],
                    {ok, Data#conn_data{datagram_queue = Queue}};
                _ ->
                    Data#conn_data.owner ! {quic_datagram, self(), DGData},
                    {ok, Data}
            end
    end;

process_frame({new_connection_id, _SeqNum, _RetirePriorTo, _CID, _Token}, _Level, Data) ->
    {ok, Data};

process_frame(_Frame, _Level, Data) ->
    %% Unknown/unhandled frame - ignore
    {ok, Data}.

%% ===================================================================
%% TLS Action Processing
%% ===================================================================

process_tls_actions([], Data) -> Data;
process_tls_actions([Action | Rest], Data) ->
    Data2 = process_tls_action(Action, Data),
    process_tls_actions(Rest, Data2).

process_tls_action({send_crypto, Level, CryptoData}, Data) ->
    send_crypto_data(CryptoData, Level, Data);

process_tls_action({handshake_keys, Keys}, Data) ->
    Data#conn_data{handshake_keys = Keys};

process_tls_action({application_keys, Keys, ClientSecret, ServerSecret}, Data) ->
    io:format("[conn:~p] app keys installed~n", [self()]),
    Data#conn_data{app_keys = Keys,
                   client_app_secret = ClientSecret,
                   server_app_secret = ServerSecret};
process_tls_action({application_keys, Keys}, Data) ->
    io:format("[conn:~p] app keys installed (no secrets)~n", [self()]),
    Data#conn_data{app_keys = Keys};

process_tls_action({handshake_complete, _ALPN, RemoteParams}, Data) ->
    Data#conn_data{
        handshake_done = true,
        remote_params = RemoteParams,
        max_data_remote = case RemoteParams of
            #transport_params{initial_max_data = V} -> V;
            _ -> 0
        end
    };

process_tls_action(send_handshake_done, Data) ->
    %% Server sends HANDSHAKE_DONE frame in 1-RTT packet
    HDFrame = quic_frame:encode(handshake_done),
    send_app_data(HDFrame, Data);

process_tls_action(_, Data) ->
    Data.

%% ===================================================================
%% Packet Sending
%% ===================================================================

send_crypto_data(CryptoData, initial, Data) ->
    %% Send in an Initial packet with ACK for client's Initial
    AckFrame = quic_frame:encode({ack, 0, 0, [0]}),
    CryptoFrame = quic_frame:encode({crypto, 0, CryptoData}),
    Payload = <<AckFrame/binary, CryptoFrame/binary>>,
    #{server := ServerKeys} = Data#conn_data.initial_keys,
    Keys = case Data#conn_data.role of
        server -> ServerKeys;
        client ->
            #{client := CK} = Data#conn_data.initial_keys,
            CK
    end,
    PNSpaces = Data#conn_data.pn_spaces,
    InitPN = maps:get(initial, PNSpaces),
    PN = InitPN#pn_space.next_pn,

    Packet = quic_packet:encode_initial(
        Data#conn_data.dcid, Data#conn_data.scid,
        <<>>, PN, Payload),

    ProtectedPacket = protect_initial_packet(Packet, PN, Keys),
    send_udp(ProtectedPacket, Data),

    NewPNSpaces = PNSpaces#{initial => InitPN#pn_space{next_pn = PN + 1}},
    Data#conn_data{pn_spaces = NewPNSpaces};

send_crypto_data(CryptoData, handshake, Data) ->
    CryptoFrame = quic_frame:encode({crypto, 0, CryptoData}),
    HSKeys = Data#conn_data.handshake_keys,
    Keys = case Data#conn_data.role of
        server -> maps:get(server, HSKeys);
        client -> maps:get(client, HSKeys)
    end,
    PNSpaces = Data#conn_data.pn_spaces,
    HSPN = maps:get(handshake, PNSpaces),
    PN = HSPN#pn_space.next_pn,

    Packet = quic_packet:encode_handshake(
        Data#conn_data.dcid, Data#conn_data.scid, PN, CryptoFrame),
    ProtectedPacket = protect_long_packet(Packet, PN, Keys),
    send_udp(ProtectedPacket, Data),

    NewPNSpaces = PNSpaces#{handshake => HSPN#pn_space{next_pn = PN + 1}},
    Data#conn_data{pn_spaces = NewPNSpaces};

send_crypto_data(_CryptoData, _Level, Data) ->
    Data.

%% Send ACK for client's Handshake packet
send_handshake_ack(Data) ->
    case Data#conn_data.handshake_keys of
        undefined -> Data;
        HSKeys ->
            AckFrame = quic_frame:encode({ack, 0, 0, [0]}),
            Keys = case Data#conn_data.role of
                server -> maps:get(server, HSKeys);
                client -> maps:get(client, HSKeys)
            end,
            PNSpaces = Data#conn_data.pn_spaces,
            HSPN = maps:get(handshake, PNSpaces),
            PN = HSPN#pn_space.next_pn,
            Packet = quic_packet:encode_handshake(
                Data#conn_data.dcid, Data#conn_data.scid, PN, AckFrame),
            ProtectedPacket = protect_long_packet(Packet, PN, Keys),
            send_udp(ProtectedPacket, Data),
            NewPNSpaces = PNSpaces#{handshake => HSPN#pn_space{next_pn = PN + 1}},
            Data#conn_data{pn_spaces = NewPNSpaces}
    end.

send_app_ack(_RecvPN, Data) ->
    PNSpaces = Data#conn_data.pn_spaces,
    AppPNSpace = maps:get(application, PNSpaces),
    RecvPNs = AppPNSpace#pn_space.received_pns,
    case RecvPNs of
        [] -> Data;
        _ ->
            Ranges = build_ack_ranges(lists:reverse(RecvPNs)),
            LargestAcked = hd(lists:reverse(RecvPNs)),
            AckFrame = quic_frame:encode({ack, LargestAcked, 0, Ranges}),
            send_app_data(AckFrame, Data)
    end.

build_ack_ranges(SortedDescPNs) ->
    Blocks = group_contiguous(SortedDescPNs),
    [{High, Low} | Rest] = Blocks,
    [High - Low | build_gap_ranges(Rest, Low)].

group_contiguous([PN | Rest]) ->
    group_contiguous(Rest, PN, PN, []).

group_contiguous([], High, Low, Acc) ->
    lists:reverse([{High, Low} | Acc]);
group_contiguous([PN | Rest], _High, Low, Acc) when Low - 1 =:= PN ->
    group_contiguous(Rest, _High, PN, Acc);
group_contiguous([PN | Rest], High, Low, Acc) ->
    group_contiguous(Rest, PN, PN, [{High, Low} | Acc]).

build_gap_ranges([], _PrevLow) -> [];
build_gap_ranges([{High, Low} | Rest], PrevLow) ->
    [{PrevLow - High - 2, High - Low} | build_gap_ranges(Rest, Low)].

send_stream_frames(Frames, Data) ->
    FramesBin = iolist_to_binary([quic_frame:encode(F) || F <- Frames]),
    send_app_data(FramesBin, Data).

send_app_data(FrameData, Data) ->
    case Data#conn_data.app_keys of
        undefined ->
            Data;
        AppKeys ->
            Keys = case Data#conn_data.role of
                client -> maps:get(client, AppKeys);
                server -> maps:get(server, AppKeys)
            end,
            PNSpaces = Data#conn_data.pn_spaces,
            AppPN = maps:get(application, PNSpaces),
            PN = AppPN#pn_space.next_pn,

            %% Pad payload to at least 4 bytes (RFC 9001 §5.4.2: sample requires it)
            PaddedFrameData = case byte_size(FrameData) < 4 of
                true -> <<FrameData/binary, 0:(8 * (4 - byte_size(FrameData)))>>;
                false -> FrameData
            end,
            Packet = quic_packet:encode_short(
                Data#conn_data.dcid, PN, PaddedFrameData,
                Data#conn_data.key_phase),
            ProtectedPacket = protect_short_packet(Packet, PN, Keys,
                                                    byte_size(Data#conn_data.dcid)),
            send_udp(ProtectedPacket, Data),

            NewPNSpaces = PNSpaces#{application => AppPN#pn_space{next_pn = PN + 1}},
            Data#conn_data{pn_spaces = NewPNSpaces}
    end.

send_udp(Packet, #conn_data{udp_socket = Socket, peer_addr = PeerAddr}) ->
    socket:sendto(Socket, Packet, PeerAddr).

%% ===================================================================
%% Packet Protection Helpers
%% ===================================================================

protect_initial_packet(Packet, PN, {Key, IV, HPKey}) ->
    %% For Initial packets, we need proper header protection
    protect_long_packet(Packet, PN, {Key, IV, HPKey}).

protect_long_packet(Packet, PN, {Key, IV, HPKey}) ->
    %% Find PN location in the packet
    PNOffset = find_long_pn_offset(Packet),
    <<FB:8, _/binary>> = Packet,
    PNLen = (FB band 16#03) + 1,
    HeaderLen = PNOffset + PNLen,
    <<Header:HeaderLen/binary, Payload/binary>> = Packet,

    %% Encrypt payload
    Nonce = quic_crypto:make_nonce(IV, PN),
    {CipherText, Tag} = crypto:crypto_one_time_aead(
        aead_cipher(byte_size(Key)), Key, Nonce, Payload, Header, 16, true),
    CipherPayload = <<CipherText/binary, Tag/binary>>,

    %% Get sample for header protection (starts 4 bytes from PN offset)
    SampleStart = 4 - PNLen,
    <<_:SampleStart/binary, Sample:16/binary, _/binary>> = CipherPayload,

    %% Apply header protection
    Mask = hp_mask(HPKey, Sample),
    <<M0:8, M1:8, M2:8, M3:8, M4:8>> = Mask,

    NewFB = FB bxor (M0 band 16#0f),
    <<_:PNOffset/binary, PNBytes:PNLen/binary, _/binary>> = Packet,
    MaskPN = binary:part(<<M1, M2, M3, M4>>, 0, PNLen),
    NewPN = crypto:exor(PNBytes, MaskPN),

    <<_Pre:1/binary, Mid:(PNOffset-1)/binary, _:PNLen/binary, _/binary>> = Packet,
    <<NewFB:8, Mid/binary, NewPN/binary, CipherPayload/binary>>.

protect_short_packet(Packet, PN, {Key, IV, HPKey}, DCIDLen) ->
    PNOffset = 1 + DCIDLen,
    <<FB:8, _/binary>> = Packet,
    PNLen = (FB band 16#03) + 1,
    HeaderLen = PNOffset + PNLen,
    <<Header:HeaderLen/binary, Payload/binary>> = Packet,

    %% Encrypt payload
    Nonce = quic_crypto:make_nonce(IV, PN),
    {CipherText, Tag} = crypto:crypto_one_time_aead(
        aead_cipher(byte_size(Key)), Key, Nonce, Payload, Header, 16, true),
    CipherPayload = <<CipherText/binary, Tag/binary>>,

    %% Sample for HP
    SampleStart = 4 - PNLen,
    case byte_size(CipherPayload) >= SampleStart + 16 of
        true ->
            <<_:SampleStart/binary, Sample:16/binary, _/binary>> = CipherPayload,
            Mask = hp_mask(HPKey, Sample),
            <<M0:8, M1:8, M2:8, M3:8, M4:8>> = Mask,
            NewFB = FB bxor (M0 band 16#1f),
            <<_:PNOffset/binary, PNBytes:PNLen/binary, _/binary>> = Packet,
            MaskPN = binary:part(<<M1, M2, M3, M4>>, 0, PNLen),
            NewPN = crypto:exor(PNBytes, MaskPN),
            <<_Pre:1/binary, DCID:DCIDLen/binary, _:PNLen/binary, _/binary>> = Packet,
            <<NewFB:8, DCID/binary, NewPN/binary, CipherPayload/binary>>;
        false ->
            %% Payload too short for proper HP, send as-is
            Packet
    end.

find_long_pn_offset(Packet) ->
    <<_FB:8, _Version:32, DCIDLen:8, _DCID:DCIDLen/binary,
      SCIDLen:8, _SCID:SCIDLen/binary, Rest/binary>> = Packet,
    BaseOffset = 1 + 4 + 1 + DCIDLen + 1 + SCIDLen,
    <<FB:8, _/binary>> = Packet,
    Type = (FB band 16#30) bsr 4,
    {TokenFieldLen, R2} = case Type of
        ?INITIAL_PACKET ->
            {TLen, R1} = quic_varint:decode(Rest),
            TokenVarIntLen = byte_size(Rest) - byte_size(R1),
            <<_Token:TLen/binary, AfterToken/binary>> = R1,
            {TokenVarIntLen + TLen, AfterToken};
        _ ->
            {0, Rest}
    end,
    {_Length, R3} = quic_varint:decode(R2),
    LenFieldLen = byte_size(R2) - byte_size(R3),
    BaseOffset + TokenFieldLen + LenFieldLen.

hp_mask(HPKey, Sample) when byte_size(HPKey) =:= 16 ->
    <<Mask:5/binary, _/binary>> = crypto:crypto_one_time(aes_128_ecb, HPKey, Sample, true),
    Mask;
hp_mask(HPKey, Sample) when byte_size(HPKey) =:= 32 ->
    <<Mask:5/binary, _/binary>> = crypto:crypto_one_time(aes_256_ecb, HPKey, Sample, true),
    Mask.

aead_cipher(16) -> aes_128_gcm;
aead_cipher(32) -> aes_256_gcm.

%% ===================================================================
%% Helpers
%% ===================================================================

start_recv(Socket) ->
    socket:recvfrom(Socket, 0, [], nowait).

resolve_host(Host) when is_tuple(Host) -> Host;
resolve_host(Host) when is_list(Host) ->
    case inet:getaddr(Host, inet) of
        {ok, Addr} -> Addr;
        _ -> {127, 0, 0, 1}
    end;
resolve_host(Host) when is_binary(Host) ->
    resolve_host(binary_to_list(Host)).

level_to_pn_space(initial) -> initial;
level_to_pn_space(handshake) -> handshake;
level_to_pn_space(application) -> application;
level_to_pn_space(_) -> application.

extract_crypto_data(Frames) ->
    iolist_to_binary([Data || {crypto, _Offset, Data} <- Frames]).

get_or_create_stream(StreamId, Data) ->
    case maps:find(StreamId, Data#conn_data.streams) of
        {ok, Stream} ->
            {Stream, Data};
        error ->
            %% Auto-create peer-initiated stream
            MaxRecv = Data#conn_data.local_params#transport_params.initial_max_stream_data_bidi_remote,
            MaxSend = case Data#conn_data.remote_params of
                #transport_params{initial_max_stream_data_bidi_local = V} -> V;
                _ -> 65536
            end,
            Stream = quic_stream:new(StreamId, MaxSend, MaxRecv),
            Streams = maps:put(StreamId, Stream, Data#conn_data.streams),

            %% Notify stream acceptors
            Data2 = case Data#conn_data.stream_acceptors of
                [{From, _} | Rest] ->
                    StreamRef = {quic_stream, self(), StreamId},
                    gen_statem:reply(From, {ok, StreamRef}),
                    Data#conn_data{streams = Streams, stream_acceptors = Rest};
                [] ->
                    %% Notify owner in active mode
                    case Data#conn_data.active of
                        false -> ok;
                        _ ->
                            StreamRef = {quic_stream, self(), StreamId},
                            Data#conn_data.owner ! {quic_stream_opened, self(), StreamRef}
                    end,
                    Data#conn_data{streams = Streams}
            end,
            {Stream, Data2}
    end.

allocate_stream_id(bidirectional, Data) ->
    Id = Data#conn_data.next_bidi_stream,
    {Id, Data#conn_data{next_bidi_stream = Id + 4}};
allocate_stream_id(unidirectional, Data) ->
    Id = Data#conn_data.next_uni_stream,
    {Id, Data#conn_data{next_uni_stream = Id + 4}}.

maybe_deliver_stream_data(StreamId, Stream, Data) ->
    case Data#conn_data.active of
        false ->
            %% Passive mode - notify waiters
            quic_stream:notify_recv_waiters(Stream);
        _ ->
            %% Active mode - deliver to owner
            {ReadData, Stream2} = quic_stream:read(Stream),
            case byte_size(ReadData) > 0 of
                true ->
                    StreamRef = {quic_stream, self(), StreamId},
                    Data#conn_data.owner ! {quic, StreamRef, ReadData},
                    case Stream2#quic_stream.fin_received andalso
                         Stream2#quic_stream.recv_state =:= data_read of
                        true ->
                            Data#conn_data.owner ! {quic_stream_closed, StreamRef};
                        false -> ok
                    end,
                    Stream2;
                false ->
                    Stream
            end
    end.

%% Drain all available packets from the socket during handshake.
%% Needed because multiple server response datagrams may arrive
%% before the next select notification.
handshake_drain(Socket, Data) ->
    case socket:recvfrom(Socket, 0, [], nowait) of
        {ok, {_Source, PacketData}} ->
            case process_received_packet(PacketData, Data) of
                {ok, Data2} ->
                    %% Send ACK if handshake just completed
                    Data3 = case Data2#conn_data.handshake_done of
                        true -> send_handshake_ack(Data2);
                        false -> Data2
                    end,
                    %% Try to read more packets immediately
                    self() ! {handshake_drain, Socket},
                    maybe_transition_to_established(Data3);
                {error, Reason} ->
                    start_recv(Socket),
                    {keep_state, Data}
            end;
        {select, _} ->
            %% No more data available, wait for next notification
            {keep_state, Data};
        {error, _} ->
            {keep_state, Data}
    end.

idle_timeout_action(#conn_data{idle_timeout = Timeout}) ->
    {{timeout, idle}, Timeout, idle_timeout}.

start_keepalive_timer(IdleTimeout) ->
    erlang:send_after(IdleTimeout div 2, self(), keepalive).

maybe_transition_to_established(Data) ->
    %% Check if handshake is fully complete (app keys + TLS handshake done)
    case {Data#conn_data.app_keys, Data#conn_data.handshake_done} of
        {undefined, _} ->
            {keep_state, Data};
        {_, false} ->
            {keep_state, Data};
        {_, true} ->
            %% Notify waiting callers
            lists:foreach(fun({From, _}) ->
                gen_statem:reply(From, {ok, self()})
            end, Data#conn_data.conn_waiters),
            start_keepalive_timer(Data#conn_data.idle_timeout),
            {next_state, established,
             Data#conn_data{conn_waiters = []},
             [idle_timeout_action(Data)]}
    end.

build_local_params(Opts, SCID) ->
    #transport_params{
        initial_max_data = proplists:get_value(initial_max_data, Opts, 1048576),
        initial_max_stream_data_bidi_local =
            proplists:get_value(initial_max_stream_data_bidi_local, Opts, 65536),
        initial_max_stream_data_bidi_remote =
            proplists:get_value(initial_max_stream_data_bidi_remote, Opts, 65536),
        initial_max_stream_data_uni =
            proplists:get_value(initial_max_stream_data_uni, Opts, 65536),
        initial_max_streams_bidi =
            proplists:get_value(initial_max_streams_bidi, Opts, 100),
        initial_max_streams_uni =
            proplists:get_value(initial_max_streams_uni, Opts, 100),
        max_idle_timeout =
            proplists:get_value(max_idle_timeout, Opts, 30000),
        active_connection_id_limit = 8,
        max_datagram_frame_size =
            proplists:get_value(max_datagram_frame_size, Opts, 65535),
        initial_source_connection_id = SCID,
        grease_quic_bit = true
    }.

handle_common_info({'DOWN', _MonRef, process, Owner, _Reason},
                   _State, #conn_data{owner = Owner} = Data) ->
    {stop, normal, Data};
handle_common_info(_Msg, _State, _Data) ->
    keep_state_and_data.
