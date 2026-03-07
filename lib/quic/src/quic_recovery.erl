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

-module(quic_recovery).

-include("quic.hrl").

-export([
    init/0,
    init/1,
    on_packet_sent/5,
    on_ack_received/5,
    on_packet_lost/2,
    get_pto/1,
    get_pto/2,
    get_loss_timeout/1,
    detect_lost_packets/3,
    on_congestion_event/2,
    set_max_ack_delay/2,
    set_loss_detection_timer/1,
    on_loss_detection_timeout/1,
    on_pn_space_discarded/2,
    in_persistent_congestion/2
]).

-define(PACKET_THRESHOLD, 3).
-define(TIME_THRESHOLD_NUM, 9).
-define(TIME_THRESHOLD_DEN, 8).
-define(INITIAL_RTT, 333).
-define(TIMER_GRANULARITY, 1).
-define(MAX_PTO, 60000).
-define(PERSISTENT_CONGESTION_THRESHOLD, 3).

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
        first_rtt_sample = false,
        max_ack_delay = ?DEFAULT_MAX_ACK_DELAY,
        sent_packets = #{
            initial => #{},
            handshake => #{},
            application => #{}
        },
        congestion_window = InitialWindow,
        bytes_in_flight = 0,
        ssthresh = infinity,
        pto_count = 0,
        max_datagram_size = MaxDatagramSize
    }.

%% ===================================================================
%% Packet Sent Tracking
%% ===================================================================

-spec on_packet_sent(non_neg_integer(), non_neg_integer(), boolean(), atom(), #recovery{}) ->
    #recovery{}.
on_packet_sent(PacketNumber, SentBytes, AckEliciting, PNSpace, Recovery) ->
    Now = erlang:monotonic_time(millisecond),
    InFlight = SentBytes > 0 andalso AckEliciting,
    SentInfo = #{
        packet_number => PacketNumber,
        time_sent => Now,
        sent_bytes => SentBytes,
        ack_eliciting => AckEliciting,
        in_flight => InFlight
    },
    SpaceMap = maps:get(PNSpace, Recovery#recovery.sent_packets),
    NewSpaceMap = maps:put(PacketNumber, SentInfo, SpaceMap),
    NewSentPackets = maps:put(PNSpace, NewSpaceMap, Recovery#recovery.sent_packets),
    NewBIF = case InFlight of
        true -> Recovery#recovery.bytes_in_flight + SentBytes;
        false -> Recovery#recovery.bytes_in_flight
    end,
    Recovery#recovery{
        sent_packets = NewSentPackets,
        bytes_in_flight = NewBIF
    }.

%% ===================================================================
%% ACK Processing
%% ===================================================================

-spec on_ack_received(non_neg_integer(), non_neg_integer(), [non_neg_integer()], atom(), #recovery{}) ->
    {[non_neg_integer()], non_neg_integer(), #recovery{}}.
on_ack_received(LargestAcked, AckDelay, AckedPNs, PNSpace, Recovery) ->
    SpaceMap = maps:get(PNSpace, Recovery#recovery.sent_packets),

    %% Update RTT from the largest acked packet
    Recovery1 = case maps:find(LargestAcked, SpaceMap) of
        {ok, #{time_sent := TimeSent}} ->
            Now = erlang:monotonic_time(millisecond),
            LatestRTT = max(1, Now - TimeSent),
            ScaledAckDelay = case PNSpace of
                application -> AckDelay;
                _ -> 0
            end,
            update_rtt(LatestRTT, ScaledAckDelay, Recovery);
        error ->
            Recovery
    end,

    %% Remove acked packets from sent_packets, sum acked bytes
    {NewSpaceMap, AckedBytes} = lists:foldl(
        fun(PN, {SM, Bytes}) ->
            case maps:take(PN, SM) of
                {#{in_flight := true, sent_bytes := SB}, SM2} ->
                    {SM2, Bytes + SB};
                {_, SM2} ->
                    {SM2, Bytes};
                error ->
                    {SM, Bytes}
            end
        end,
        {SpaceMap, 0},
        AckedPNs
    ),

    NewSentPackets = maps:put(PNSpace, NewSpaceMap, Recovery1#recovery.sent_packets),
    NewBIF = max(0, Recovery1#recovery.bytes_in_flight - AckedBytes),
    Recovery2 = Recovery1#recovery{
        sent_packets = NewSentPackets,
        bytes_in_flight = NewBIF
    },

    %% Congestion window growth
    Recovery3 = on_packets_acked(AckedBytes, Recovery2),

    %% Detect lost packets
    {LostPackets, Recovery4} = detect_lost_packets(LargestAcked, PNSpace, Recovery3),

    %% Sum lost bytes for congestion
    LostBytes = lists:foldl(
        fun(PN, Acc) ->
            case maps:find(PN, SpaceMap) of
                {ok, #{sent_bytes := SB}} -> Acc + SB;
                _ -> Acc
            end
        end, 0, LostPackets),

    Recovery5 = case LostBytes > 0 of
        true -> on_congestion_event(LostBytes, Recovery4);
        false -> Recovery4
    end,

    Recovery6 = Recovery5#recovery{pto_count = 0},
    {LostPackets, AckedBytes, Recovery6}.

%% ===================================================================
%% RTT Estimation (RFC 9002, Section 5.3)
%% ===================================================================

update_rtt(LatestRTT, AckDelay, #recovery{min_rtt = MinRTT} = R) ->
    NewMinRTT = case MinRTT of
        infinity -> LatestRTT;
        _ -> min(MinRTT, LatestRTT)
    end,

    AdjustedRTT = case LatestRTT > NewMinRTT + AckDelay of
        true -> LatestRTT - AckDelay;
        false -> LatestRTT
    end,

    {NewSRTT, NewRTTVar} = case R#recovery.first_rtt_sample of
        false ->
            {AdjustedRTT, AdjustedRTT / 2};
        true ->
            SRTT = R#recovery.smoothed_rtt,
            RttVar = R#recovery.rttvar,
            NewRV = 0.75 * RttVar + 0.25 * abs(SRTT - AdjustedRTT),
            NewSR = 0.875 * SRTT + 0.125 * AdjustedRTT,
            {NewSR, NewRV}
    end,

    R#recovery{
        latest_rtt = LatestRTT,
        min_rtt = NewMinRTT,
        smoothed_rtt = NewSRTT,
        rttvar = NewRTTVar,
        first_rtt_sample = true
    }.

%% ===================================================================
%% Loss Detection (RFC 9002, Section 6)
%% ===================================================================

-spec detect_lost_packets(non_neg_integer(), atom(), #recovery{}) ->
    {[non_neg_integer()], #recovery{}}.
detect_lost_packets(LargestAcked, PNSpace, Recovery) ->
    MaxRTT = max(Recovery#recovery.smoothed_rtt, Recovery#recovery.latest_rtt),
    TimeThreshold = max(round(MaxRTT * ?TIME_THRESHOLD_NUM / ?TIME_THRESHOLD_DEN),
                        ?TIMER_GRANULARITY),
    Now = erlang:monotonic_time(millisecond),
    LossDeadline = Now - TimeThreshold,

    PacketThresholdPN = case LargestAcked >= ?PACKET_THRESHOLD of
        true -> LargestAcked - ?PACKET_THRESHOLD;
        false -> -1
    end,

    SpaceMap = maps:get(PNSpace, Recovery#recovery.sent_packets),

    {LostPNs, NewSpaceMap, LostBIF} = maps:fold(
        fun(PN, #{time_sent := TimeSent, in_flight := InFlight, sent_bytes := SB} = _Info,
            {Lost, SM, BIF}) ->
            IsLost = (PN =< PacketThresholdPN) orelse (TimeSent =< LossDeadline),
            case IsLost andalso PN =< LargestAcked of
                true ->
                    LostBIF2 = case InFlight of true -> BIF + SB; false -> BIF end,
                    {[PN | Lost], maps:remove(PN, SM), LostBIF2};
                false ->
                    {Lost, SM, BIF}
            end
        end,
        {[], SpaceMap, 0},
        SpaceMap
    ),

    NewSentPackets = maps:put(PNSpace, NewSpaceMap, Recovery#recovery.sent_packets),
    NewBIF = max(0, Recovery#recovery.bytes_in_flight - LostBIF),

    EarliestLoss = case maps:size(NewSpaceMap) > 0 of
        true ->
            maps:fold(fun(_PN, #{time_sent := TS}, Min) ->
                case Min of undefined -> TS; _ -> min(TS, Min) end
            end, undefined, NewSpaceMap);
        false ->
            undefined
    end,
    NewLossTime = case EarliestLoss of
        undefined -> undefined;
        T -> T + TimeThreshold
    end,

    LossTimeMap = maps:put(PNSpace, NewLossTime, Recovery#recovery.loss_time),

    {lists:sort(LostPNs), Recovery#recovery{
        sent_packets = NewSentPackets,
        bytes_in_flight = NewBIF,
        loss_time = LossTimeMap
    }}.

%% @doc Handle a packet loss event (external call).
-spec on_packet_lost(non_neg_integer(), #recovery{}) -> #recovery{}.
on_packet_lost(LostBytes, Recovery) ->
    NewBIF = max(0, Recovery#recovery.bytes_in_flight - LostBytes),
    on_congestion_event(LostBytes,
                        Recovery#recovery{bytes_in_flight = NewBIF}).

%% ===================================================================
%% Congestion Control (RFC 9002, Section 7 — NewReno)
%% ===================================================================

on_packets_acked(0, Recovery) ->
    Recovery;
on_packets_acked(AckedBytes, Recovery) ->
    CW = Recovery#recovery.congestion_window,
    MDS = Recovery#recovery.max_datagram_size,
    SSThresh = Recovery#recovery.ssthresh,
    NewCW = case SSThresh of
        infinity ->
            CW + AckedBytes;
        _ when CW < SSThresh ->
            CW + AckedBytes;
        _ ->
            CW + max(1, trunc(MDS * AckedBytes / CW))
    end,
    Recovery#recovery{congestion_window = NewCW}.

-spec on_congestion_event(non_neg_integer(), #recovery{}) -> #recovery{}.
on_congestion_event(_LostBytes, Recovery) ->
    Now = erlang:monotonic_time(millisecond),
    case Recovery#recovery.congestion_recovery_start_time of
        CRStart when is_integer(CRStart), Now =< CRStart + round(Recovery#recovery.smoothed_rtt) ->
            Recovery;
        _ ->
            CW = Recovery#recovery.congestion_window,
            MDS = Recovery#recovery.max_datagram_size,
            NewCW = max(trunc(CW * ?LOSS_REDUCTION_FACTOR),
                        ?MINIMUM_WINDOW_PACKETS * MDS),
            Recovery#recovery{
                congestion_window = NewCW,
                ssthresh = NewCW,
                congestion_recovery_start_time = Now
            }
    end.

%% ===================================================================
%% PTO Calculation (RFC 9002, Section 6.2)
%% ===================================================================

-spec get_pto(#recovery{}) -> number().
get_pto(Recovery) ->
    get_pto(Recovery, application).

-spec get_pto(#recovery{}, atom()) -> number().
get_pto(#recovery{smoothed_rtt = SRTT, rttvar = RTTVar,
                   max_ack_delay = MaxAckDelay, pto_count = PTOCount}, PNSpace) ->
    MAD = case PNSpace of
        application -> MaxAckDelay;
        _ -> 0
    end,
    PTO = SRTT + max(4 * RTTVar, ?TIMER_GRANULARITY) + MAD,
    min(PTO * math:pow(2, PTOCount), ?MAX_PTO).

-spec get_loss_timeout(#recovery{}) -> number() | infinity.
get_loss_timeout(#recovery{loss_time = LossTimeMap}) ->
    Times = [T || {_, T} <- maps:to_list(LossTimeMap), T =/= undefined],
    case Times of
        [] -> infinity;
        _ -> lists:min(Times)
    end.

-spec set_max_ack_delay(non_neg_integer(), #recovery{}) -> #recovery{}.
set_max_ack_delay(MaxAckDelay, Recovery) ->
    Recovery#recovery{max_ack_delay = MaxAckDelay}.

%% ===================================================================
%% Loss Detection Timer (RFC 9002, Appendix A.8)
%% ===================================================================

%% @doc Compute when the loss detection timer should fire.
%% Returns {Time, Space} where Time is an absolute monotonic ms timestamp,
%% or {infinity, undefined} if no timer needed.
-spec set_loss_detection_timer(#recovery{}) ->
    {number() | infinity, atom() | undefined}.
set_loss_detection_timer(Recovery) ->
    %% First check loss_time across all spaces (A.8: earliest loss time)
    case get_loss_time_and_space(Recovery) of
        {LossTime, Space} when LossTime =/= undefined ->
            {LossTime, Space};
        _ ->
            %% No loss time set — check if there are any in-flight packets
            HasInFlight = has_ack_eliciting_in_flight(Recovery),
            case HasInFlight of
                false ->
                    {infinity, undefined};
                true ->
                    %% Use PTO (A.8)
                    {PTOTime, PTOSpace} = get_pto_time_and_space(Recovery),
                    {PTOTime, PTOSpace}
            end
    end.

%% @doc Handle loss detection timeout (RFC 9002, Appendix A.9).
%% Returns {action, Space, Recovery} where action is:
%%   detect_lost — run loss detection for the space
%%   send_probe — send 1-2 probe packets in the space
-spec on_loss_detection_timeout(#recovery{}) ->
    {detect_lost, atom(), #recovery{}} | {send_probe, atom(), #recovery{}}.
on_loss_detection_timeout(Recovery) ->
    case get_loss_time_and_space(Recovery) of
        {LossTime, Space} when LossTime =/= undefined ->
            %% Time threshold loss (A.9)
            {detect_lost, Space, Recovery};
        _ ->
            %% PTO timeout — send probe packets (A.9)
            {_PTOTime, PTOSpace} = get_pto_time_and_space(Recovery),
            NewRecovery = Recovery#recovery{
                pto_count = Recovery#recovery.pto_count + 1
            },
            {send_probe, PTOSpace, NewRecovery}
    end.

%% ===================================================================
%% Packet Number Space Discard (RFC 9002, Appendix A.11)
%% ===================================================================

%% @doc Called when Initial or Handshake keys are discarded.
%% Removes bytes_in_flight for all packets in the space and resets state.
-spec on_pn_space_discarded(atom(), #recovery{}) -> #recovery{}.
on_pn_space_discarded(PNSpace, Recovery) ->
    SpaceMap = maps:get(PNSpace, Recovery#recovery.sent_packets),
    %% Sum bytes_in_flight for all in-flight packets in this space
    DroppedBytes = maps:fold(
        fun(_PN, #{in_flight := true, sent_bytes := SB}, Acc) -> Acc + SB;
           (_PN, _, Acc) -> Acc
        end, 0, SpaceMap),
    NewSentPackets = maps:put(PNSpace, #{}, Recovery#recovery.sent_packets),
    NewLossTime = maps:put(PNSpace, undefined, Recovery#recovery.loss_time),
    NewBIF = max(0, Recovery#recovery.bytes_in_flight - DroppedBytes),
    Recovery#recovery{
        sent_packets = NewSentPackets,
        bytes_in_flight = NewBIF,
        loss_time = NewLossTime
    }.

%% ===================================================================
%% Persistent Congestion (RFC 9002, Section 7.6)
%% ===================================================================

%% @doc Check if a set of lost packets indicates persistent congestion.
%% LostPackets is a list of #{time_sent := integer()} maps.
-spec in_persistent_congestion([map()], #recovery{}) -> boolean().
in_persistent_congestion([], _Recovery) ->
    false;
in_persistent_congestion(LostPackets, Recovery) ->
    SRTT = Recovery#recovery.smoothed_rtt,
    RTTVar = Recovery#recovery.rttvar,
    MAD = Recovery#recovery.max_ack_delay,
    %% RFC 9002 §7.6.2: congestion_period = smoothed_rtt + max(4*rttvar, granularity) + max_ack_delay
    CongestionPeriod = (SRTT + max(4 * RTTVar, ?TIMER_GRANULARITY) + MAD)
                       * ?PERSISTENT_CONGESTION_THRESHOLD,
    %% Check if any two consecutive lost packets span longer than congestion_period
    SortedTimes = lists:sort([T || #{time_sent := T} <- LostPackets]),
    case {lists:min(SortedTimes), lists:max(SortedTimes)} of
        {Earliest, Latest} when Latest - Earliest > CongestionPeriod ->
            true;
        _ ->
            false
    end.

%% ===================================================================
%% Internal Helpers
%% ===================================================================

get_loss_time_and_space(#recovery{loss_time = LTMap}) ->
    %% Find the earliest non-undefined loss time across all spaces
    maps:fold(
        fun(Space, Time, {BestTime, _BestSpace}) when
              Time =/= undefined, (BestTime =:= undefined orelse Time < BestTime) ->
                {Time, Space};
           (_Space, _Time, Acc) ->
                Acc
        end,
        {undefined, undefined},
        LTMap
    ).

get_pto_time_and_space(Recovery) ->
    %% Find the space with earliest PTO expiry among spaces with in-flight data
    Spaces = [initial, handshake, application],
    lists:foldl(
        fun(Space, {BestTime, BestSpace}) ->
            SpaceMap = maps:get(Space, Recovery#recovery.sent_packets),
            case has_ack_eliciting_in_space(SpaceMap) of
                false ->
                    {BestTime, BestSpace};
                true ->
                    %% Find the earliest sent time in this space
                    EarliestSent = maps:fold(
                        fun(_PN, #{time_sent := TS, ack_eliciting := true}, Min) ->
                                case Min of undefined -> TS; _ -> min(TS, Min) end;
                           (_PN, _, Min) -> Min
                        end, undefined, SpaceMap),
                    case EarliestSent of
                        undefined ->
                            {BestTime, BestSpace};
                        _ ->
                            PTO = get_pto(Recovery, Space),
                            PTOTime = EarliestSent + round(PTO),
                            case BestTime =:= infinity orelse PTOTime < BestTime of
                                true -> {PTOTime, Space};
                                false -> {BestTime, BestSpace}
                            end
                    end
            end
        end,
        {infinity, application},
        Spaces
    ).

has_ack_eliciting_in_flight(#recovery{sent_packets = SentPackets}) ->
    maps:fold(
        fun(_Space, _SpaceMap, true) ->
                true;
           (_Space, SpaceMap, false) ->
                has_ack_eliciting_in_space(SpaceMap)
        end, false, SentPackets).

has_ack_eliciting_in_space(SpaceMap) ->
    maps:fold(
        fun(_PN, #{ack_eliciting := true, in_flight := true}, _) -> true;
           (_PN, _, Acc) -> Acc
        end, false, SpaceMap).
