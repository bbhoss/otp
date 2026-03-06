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

-module(quic_recovery_SUITE).

-include("quic.hrl").

-export([all/0, groups/0]).
-export([
    recovery_rtt_test/1,
    recovery_loss_detection_test/1,
    recovery_pto_test/1,
    recovery_congestion_test/1,
    recovery_sent_packets_tracking/1
]).

all() ->
    [{group, recovery_tests}].

groups() ->
    [{recovery_tests, [sequence], [
        recovery_sent_packets_tracking,
        recovery_rtt_test,
        recovery_loss_detection_test,
        recovery_pto_test,
        recovery_congestion_test
    ]}].

%% Verify sent packets are tracked per PN space
recovery_sent_packets_tracking(_Config) ->
    R0 = quic_recovery:init(),

    %% Send packets in different spaces
    R1 = quic_recovery:on_packet_sent(0, 100, true, initial, R0),
    R2 = quic_recovery:on_packet_sent(1, 200, true, initial, R1),
    R3 = quic_recovery:on_packet_sent(0, 150, true, handshake, R2),
    R4 = quic_recovery:on_packet_sent(0, 300, true, application, R3),

    %% Check bytes in flight
    750 = R4#recovery.bytes_in_flight,

    %% Check sent_packets maps
    InitialSent = maps:get(initial, R4#recovery.sent_packets),
    2 = maps:size(InitialSent),
    true = maps:is_key(0, InitialSent),
    true = maps:is_key(1, InitialSent),

    HandshakeSent = maps:get(handshake, R4#recovery.sent_packets),
    1 = maps:size(HandshakeSent),

    AppSent = maps:get(application, R4#recovery.sent_packets),
    1 = maps:size(AppSent),

    %% Non-ack-eliciting packets should not be in_flight
    R5 = quic_recovery:on_packet_sent(2, 50, false, initial, R4),
    750 = R5#recovery.bytes_in_flight,

    ok.

%% Verify RTT converges with simulated send/ACK
recovery_rtt_test(_Config) ->
    R0 = quic_recovery:init(),

    %% Send a packet
    R1 = quic_recovery:on_packet_sent(0, 100, true, application, R0),

    %% Wait a bit to simulate RTT
    timer:sleep(5),

    %% ACK the packet
    {_Lost, _Acked, R2} = quic_recovery:on_ack_received(0, 0, [0], application, R1),

    %% RTT should be > 0 and < 100ms (we only slept 5ms)
    true = R2#recovery.latest_rtt > 0,
    true = R2#recovery.latest_rtt < 100,
    true = R2#recovery.smoothed_rtt > 0,
    true = R2#recovery.smoothed_rtt < 100,
    true = R2#recovery.min_rtt > 0,
    true = R2#recovery.first_rtt_sample,

    %% PTO count should be reset
    0 = R2#recovery.pto_count,

    %% Bytes in flight should be 0
    0 = R2#recovery.bytes_in_flight,

    ok.

%% Verify loss detection via packet threshold and time threshold
recovery_loss_detection_test(_Config) ->
    R0 = quic_recovery:init(),

    %% Send packets 0-5
    R1 = lists:foldl(fun(PN, Acc) ->
        quic_recovery:on_packet_sent(PN, 100, true, application, Acc)
    end, R0, lists:seq(0, 5)),

    600 = R1#recovery.bytes_in_flight,

    timer:sleep(5),

    %% ACK packets 3, 4, 5 (skipping 0, 1, 2)
    {Lost, _Acked, R2} = quic_recovery:on_ack_received(
        5, 0, [3, 4, 5], application, R1),

    %% Packets 0, 1, 2 should be detected as lost (packet threshold: 5 - 3 = 2)
    %% Packet 0 <= 5 - 3 = 2, packet 1 <= 2, packet 2 <= 2 — all lost
    [0, 1, 2] = Lost,

    %% Bytes in flight should account for lost + acked
    0 = R2#recovery.bytes_in_flight,

    ok.

%% Verify PTO calculation per PN space
recovery_pto_test(_Config) ->
    R0 = quic_recovery:init(),

    %% Force known RTT values
    R1 = R0#recovery{smoothed_rtt = 100, rttvar = 25, max_ack_delay = 25},

    %% Application PTO includes max_ack_delay
    AppPTO = quic_recovery:get_pto(R1, application),
    %% PTO = SRTT + max(4*RTTVar, 1) + MAD = 100 + 100 + 25 = 225
    true = abs(AppPTO - 225) < 1,

    %% Initial PTO does NOT include max_ack_delay
    InitPTO = quic_recovery:get_pto(R1, initial),
    %% PTO = SRTT + max(4*RTTVar, 1) + 0 = 100 + 100 = 200
    true = abs(InitPTO - 200) < 1,

    %% Handshake PTO does NOT include max_ack_delay
    HSPTO = quic_recovery:get_pto(R1, handshake),
    true = abs(HSPTO - 200) < 1,

    %% With pto_count = 1, PTO doubles
    R2 = R1#recovery{pto_count = 1},
    AppPTO2 = quic_recovery:get_pto(R2, application),
    true = abs(AppPTO2 - 450) < 1,

    %% PTO is capped at 60 seconds
    R3 = R1#recovery{pto_count = 20},
    PTO3 = quic_recovery:get_pto(R3, application),
    true = PTO3 =< 60000,

    ok.

%% Verify congestion window growth and reduction
recovery_congestion_test(_Config) ->
    R0 = quic_recovery:init(),
    InitialCW = R0#recovery.congestion_window,

    %% Send and ACK packets — cwnd should grow (slow start)
    R1 = quic_recovery:on_packet_sent(0, 1000, true, application, R0),
    timer:sleep(2),
    {_, _, R2} = quic_recovery:on_ack_received(0, 0, [0], application, R1),

    %% In slow start, cwnd grows by acked_bytes
    true = R2#recovery.congestion_window > InitialCW,
    %% ssthresh should still be infinity (no loss yet)
    infinity = R2#recovery.ssthresh,

    %% Simulate congestion event
    R3 = quic_recovery:on_congestion_event(500, R2),

    %% cwnd should be halved
    true = R3#recovery.congestion_window < R2#recovery.congestion_window,
    %% ssthresh should be set
    true = R3#recovery.ssthresh =/= infinity,
    %% cwnd should be at least minimum window
    MDS = R3#recovery.max_datagram_size,
    true = R3#recovery.congestion_window >= 2 * MDS,

    %% Congestion event within recovery period should be ignored
    CW3 = R3#recovery.congestion_window,
    R4 = quic_recovery:on_congestion_event(500, R3),
    CW3 = R4#recovery.congestion_window,

    ok.
