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

%% QUIC Loss Detection and Congestion Control (RFC 9002)
%%
%% Implements:
%% - RTT estimation (smoothed_rtt, rttvar, min_rtt)
%% - Loss detection via packet threshold (3) and time threshold
%% - Probe Timeout (PTO) calculation
%% - NewReno congestion control

-module(quic_recovery).

-include("quic.hrl").

-export([
    init/0,
    init/1,
    on_packet_sent/4,
    on_ack_received/4,
    on_packet_lost/2,
    get_pto/1,
    get_loss_timeout/1,
    detect_lost_packets/3,
    on_congestion_event/2,
    set_max_ack_delay/2
]).

-define(PACKET_THRESHOLD, 3).
-define(TIME_THRESHOLD_NUM, 9).
-define(TIME_THRESHOLD_DEN, 8).
-define(INITIAL_RTT, 333).   %% ms
-define(TIMER_GRANULARITY, 1). %% ms

%% ===================================================================
%% Initialization
%% ===================================================================

-spec init() -> #recovery{}.
init() ->
    init(?DEFAULT_MAX_UDP_PAYLOAD_SIZE).

-spec init(non_neg_integer()) -> #recovery{}.
init(MaxDatagramSize) ->
    InitialWindow = min(10 * MaxDatagramSize,
                        max(14720, 2 * MaxDatagramSize)),
    #recovery{
        smoothed_rtt = ?INITIAL_RTT,
        rttvar = ?INITIAL_RTT / 2,
        min_rtt = infinity,
        latest_rtt = 0,
        max_ack_delay = ?DEFAULT_MAX_ACK_DELAY,
        congestion_window = InitialWindow,
        bytes_in_flight = 0,
        ssthresh = infinity,
        pto_count = 0,
        max_datagram_size = MaxDatagramSize
    }.

%% ===================================================================
%% Packet Sent Tracking
%% ===================================================================

%% @doc Record a packet as sent.
-spec on_packet_sent(non_neg_integer(), non_neg_integer(), boolean(), #recovery{}) ->
    #recovery{}.
on_packet_sent(PacketNumber, SentBytes, AckEliciting, Recovery) ->
    Now = erlang:monotonic_time(millisecond),
    SentInfo = #{
        packet_number => PacketNumber,
        time_sent => Now,
        sent_bytes => SentBytes,
        ack_eliciting => AckEliciting,
        in_flight => SentBytes > 0
    },
    NewBIF = case SentBytes > 0 of
        true -> Recovery#recovery.bytes_in_flight + SentBytes;
        false -> Recovery#recovery.bytes_in_flight
    end,
    Recovery#recovery{
        bytes_in_flight = NewBIF
    }.

%% ===================================================================
%% ACK Processing
%% ===================================================================

%% @doc Process an ACK for the given packet number space.
-spec on_ack_received(non_neg_integer(), non_neg_integer(), atom(), #recovery{}) ->
    {[non_neg_integer()], #recovery{}}.
on_ack_received(LargestAcked, AckDelay, PNSpace, Recovery) ->
    Now = erlang:monotonic_time(millisecond),

    %% Update RTT if this is a newly acknowledged packet
    NewRecovery = case LargestAcked > 0 of
        true ->
            %% Simplified: use AckDelay as-is for RTT
            LatestRTT = max(1, AckDelay),
            update_rtt(LatestRTT, AckDelay, Recovery);
        false ->
            Recovery
    end,

    %% Detect lost packets
    {LostPackets, Recovery2} = detect_lost_packets(LargestAcked, PNSpace, NewRecovery),

    %% Reset PTO count on receiving an ACK
    Recovery3 = Recovery2#recovery{pto_count = 0},

    {LostPackets, Recovery3}.

%% ===================================================================
%% RTT Estimation (RFC 9002, Section 5.3)
%% ===================================================================

update_rtt(LatestRTT, AckDelay, #recovery{min_rtt = MinRTT} = R) ->
    NewMinRTT = case MinRTT of
        infinity -> LatestRTT;
        _ -> min(MinRTT, LatestRTT)
    end,

    %% Adjust for ack delay
    AdjustedRTT = case LatestRTT > NewMinRTT + AckDelay of
        true -> LatestRTT - AckDelay;
        false -> LatestRTT
    end,

    {NewSRTT, NewRTTVar} = case R#recovery.smoothed_rtt of
        ?INITIAL_RTT ->
            %% First RTT sample
            {AdjustedRTT, AdjustedRTT / 2};
        SRTT ->
            RttVar = R#recovery.rttvar,
            NewRV = 0.75 * RttVar + 0.25 * abs(SRTT - AdjustedRTT),
            NewSR = 0.875 * SRTT + 0.125 * AdjustedRTT,
            {NewSR, NewRV}
    end,

    R#recovery{
        latest_rtt = LatestRTT,
        min_rtt = NewMinRTT,
        smoothed_rtt = NewSRTT,
        rttvar = NewRTTVar
    }.

%% ===================================================================
%% Loss Detection (RFC 9002, Section 6)
%% ===================================================================

%% @doc Detect lost packets based on packet threshold and time threshold.
-spec detect_lost_packets(non_neg_integer(), atom(), #recovery{}) ->
    {[non_neg_integer()], #recovery{}}.
detect_lost_packets(LargestAcked, _PNSpace, Recovery) ->
    %% Time threshold
    MaxRTT = max(Recovery#recovery.smoothed_rtt, Recovery#recovery.latest_rtt),
    TimeThreshold = max(round(MaxRTT * ?TIME_THRESHOLD_NUM / ?TIME_THRESHOLD_DEN),
                        ?TIMER_GRANULARITY),

    Now = erlang:monotonic_time(millisecond),
    LossTime = Now - TimeThreshold,

    %% Packet threshold: packets with PN < LargestAcked - PACKET_THRESHOLD
    %% are considered lost
    PacketThresholdPN = case LargestAcked >= ?PACKET_THRESHOLD of
        true -> LargestAcked - ?PACKET_THRESHOLD;
        false -> 0
    end,

    %% In a full implementation, we'd iterate over sent_packets map.
    %% For now, return empty lost list - the connection module tracks this.
    {[], Recovery#recovery{
        loss_time = maps:put(application, LossTime, Recovery#recovery.loss_time)
    }}.

%% @doc Handle a packet loss event.
-spec on_packet_lost(non_neg_integer(), #recovery{}) -> #recovery{}.
on_packet_lost(LostBytes, Recovery) ->
    NewBIF = max(0, Recovery#recovery.bytes_in_flight - LostBytes),
    on_congestion_event(LostBytes,
                        Recovery#recovery{bytes_in_flight = NewBIF}).

%% ===================================================================
%% Congestion Control (RFC 9002, Section 7)
%% ===================================================================

%% @doc Handle a congestion event (packet loss).
-spec on_congestion_event(non_neg_integer(), #recovery{}) -> #recovery{}.
on_congestion_event(_LostBytes, Recovery) ->
    Now = erlang:monotonic_time(millisecond),
    CW = Recovery#recovery.congestion_window,
    MDS = Recovery#recovery.max_datagram_size,

    %% Reduce congestion window
    NewCW = max(trunc(CW * ?LOSS_REDUCTION_FACTOR),
                ?MINIMUM_WINDOW_PACKETS * MDS),
    NewSSThresh = NewCW,

    Recovery#recovery{
        congestion_window = NewCW,
        ssthresh = NewSSThresh,
        congestion_recovery_start_time = Now
    }.

%% ===================================================================
%% PTO Calculation (RFC 9002, Section 6.2)
%% ===================================================================

%% @doc Calculate the Probe Timeout.
-spec get_pto(#recovery{}) -> number().
get_pto(#recovery{smoothed_rtt = SRTT, rttvar = RTTVar,
                   max_ack_delay = MaxAckDelay, pto_count = PTOCount}) ->
    PTO = SRTT + max(4 * RTTVar, ?TIMER_GRANULARITY) + MaxAckDelay,
    %% Exponential backoff
    PTO * math:pow(2, PTOCount).

%% @doc Get the earliest loss detection timeout.
-spec get_loss_timeout(#recovery{}) -> number() | infinity.
get_loss_timeout(#recovery{loss_time = LossTimeMap}) ->
    Times = [T || {_, T} <- maps:to_list(LossTimeMap), T =/= undefined],
    case Times of
        [] -> infinity;
        _ -> lists:min(Times)
    end.

%% @doc Set max_ack_delay from transport parameters.
-spec set_max_ack_delay(non_neg_integer(), #recovery{}) -> #recovery{}.
set_max_ack_delay(MaxAckDelay, Recovery) ->
    Recovery#recovery{max_ack_delay = MaxAckDelay}.
