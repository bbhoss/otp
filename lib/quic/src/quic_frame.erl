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

%% QUIC Frame Encoding/Decoding (RFC 9000, Section 19)
%%
%% Frames are the fundamental unit of communication in QUIC. Each QUIC
%% packet contains one or more frames, encoded after the packet header
%% (and decrypted).

-module(quic_frame).

-include("quic.hrl").

-export([encode/1, decode/1, decode_all/1]).

%% ===================================================================
%% Encoding
%% ===================================================================

-spec encode(tuple()) -> binary().

%% PADDING (Section 19.1)
encode(padding) ->
    <<0>>;
encode({padding, N}) when is_integer(N), N > 0 ->
    binary:copy(<<0>>, N);

%% PING (Section 19.2)
encode(ping) ->
    quic_varint:encode(?FRAME_PING);

%% ACK (Section 19.3)
encode({ack, LargestAcked, AckDelay, Ranges}) ->
    encode_ack(?FRAME_ACK, LargestAcked, AckDelay, Ranges, <<>>);

%% ACK with ECN (Section 19.3.2)
encode({ack_ecn, LargestAcked, AckDelay, Ranges, {ECT0, ECT1, ECNCE}}) ->
    ECNCounts = <<(quic_varint:encode(ECT0))/binary,
                  (quic_varint:encode(ECT1))/binary,
                  (quic_varint:encode(ECNCE))/binary>>,
    encode_ack(?FRAME_ACK_ECN, LargestAcked, AckDelay, Ranges, ECNCounts);

%% RESET_STREAM (Section 19.4)
encode({reset_stream, StreamId, AppErrorCode, FinalSize}) ->
    <<(quic_varint:encode(?FRAME_RESET_STREAM))/binary,
      (quic_varint:encode(StreamId))/binary,
      (quic_varint:encode(AppErrorCode))/binary,
      (quic_varint:encode(FinalSize))/binary>>;

%% STOP_SENDING (Section 19.5)
encode({stop_sending, StreamId, AppErrorCode}) ->
    <<(quic_varint:encode(?FRAME_STOP_SENDING))/binary,
      (quic_varint:encode(StreamId))/binary,
      (quic_varint:encode(AppErrorCode))/binary>>;

%% CRYPTO (Section 19.6)
encode({crypto, Offset, Data}) ->
    <<(quic_varint:encode(?FRAME_CRYPTO))/binary,
      (quic_varint:encode(Offset))/binary,
      (quic_varint:encode(byte_size(Data)))/binary,
      Data/binary>>;

%% NEW_TOKEN (Section 19.7)
encode({new_token, Token}) ->
    <<(quic_varint:encode(?FRAME_NEW_TOKEN))/binary,
      (quic_varint:encode(byte_size(Token)))/binary,
      Token/binary>>;

%% STREAM (Section 19.8) - type 0x08-0x0f
encode({stream, StreamId, Offset, Data, Fin}) ->
    FlagOff = if Offset > 0 -> ?STREAM_OFF_BIT; true -> 0 end,
    FlagFin = if Fin -> ?STREAM_FIN_BIT; true -> 0 end,
    %% Always include length for easier framing
    FlagLen = ?STREAM_LEN_BIT,
    FrameType = ?FRAME_STREAM bor FlagOff bor FlagFin bor FlagLen,
    OffBin = if Offset > 0 -> quic_varint:encode(Offset); true -> <<>> end,
    <<(quic_varint:encode(FrameType))/binary,
      (quic_varint:encode(StreamId))/binary,
      OffBin/binary,
      (quic_varint:encode(byte_size(Data)))/binary,
      Data/binary>>;

%% MAX_DATA (Section 19.9)
encode({max_data, MaxData}) ->
    <<(quic_varint:encode(?FRAME_MAX_DATA))/binary,
      (quic_varint:encode(MaxData))/binary>>;

%% MAX_STREAM_DATA (Section 19.10)
encode({max_stream_data, StreamId, MaxStreamData}) ->
    <<(quic_varint:encode(?FRAME_MAX_STREAM_DATA))/binary,
      (quic_varint:encode(StreamId))/binary,
      (quic_varint:encode(MaxStreamData))/binary>>;

%% MAX_STREAMS (Section 19.11)
encode({max_streams, bidi, MaxStreams}) ->
    <<(quic_varint:encode(?FRAME_MAX_STREAMS_BIDI))/binary,
      (quic_varint:encode(MaxStreams))/binary>>;
encode({max_streams, uni, MaxStreams}) ->
    <<(quic_varint:encode(?FRAME_MAX_STREAMS_UNI))/binary,
      (quic_varint:encode(MaxStreams))/binary>>;

%% DATA_BLOCKED (Section 19.12)
encode({data_blocked, MaxData}) ->
    <<(quic_varint:encode(?FRAME_DATA_BLOCKED))/binary,
      (quic_varint:encode(MaxData))/binary>>;

%% STREAM_DATA_BLOCKED (Section 19.13)
encode({stream_data_blocked, StreamId, MaxStreamData}) ->
    <<(quic_varint:encode(?FRAME_STREAM_DATA_BLOCKED))/binary,
      (quic_varint:encode(StreamId))/binary,
      (quic_varint:encode(MaxStreamData))/binary>>;

%% STREAMS_BLOCKED (Section 19.14)
encode({streams_blocked, bidi, MaxStreams}) ->
    <<(quic_varint:encode(?FRAME_STREAMS_BLOCKED_BIDI))/binary,
      (quic_varint:encode(MaxStreams))/binary>>;
encode({streams_blocked, uni, MaxStreams}) ->
    <<(quic_varint:encode(?FRAME_STREAMS_BLOCKED_UNI))/binary,
      (quic_varint:encode(MaxStreams))/binary>>;

%% NEW_CONNECTION_ID (Section 19.15)
encode({new_connection_id, SeqNum, RetirePriorTo, CID, StatelessResetToken}) ->
    CIDLen = byte_size(CID),
    <<(quic_varint:encode(?FRAME_NEW_CONNECTION_ID))/binary,
      (quic_varint:encode(SeqNum))/binary,
      (quic_varint:encode(RetirePriorTo))/binary,
      CIDLen:8,
      CID/binary,
      StatelessResetToken:16/binary>>;

%% RETIRE_CONNECTION_ID (Section 19.16)
encode({retire_connection_id, SeqNum}) ->
    <<(quic_varint:encode(?FRAME_RETIRE_CONNECTION_ID))/binary,
      (quic_varint:encode(SeqNum))/binary>>;

%% PATH_CHALLENGE (Section 19.17)
encode({path_challenge, Data}) when byte_size(Data) =:= 8 ->
    <<(quic_varint:encode(?FRAME_PATH_CHALLENGE))/binary,
      Data:8/binary>>;

%% PATH_RESPONSE (Section 19.18)
encode({path_response, Data}) when byte_size(Data) =:= 8 ->
    <<(quic_varint:encode(?FRAME_PATH_RESPONSE))/binary,
      Data:8/binary>>;

%% CONNECTION_CLOSE (Section 19.19) - transport error
encode({connection_close, ErrorCode, FrameType, ReasonPhrase}) ->
    <<(quic_varint:encode(?FRAME_CONNECTION_CLOSE))/binary,
      (quic_varint:encode(ErrorCode))/binary,
      (quic_varint:encode(FrameType))/binary,
      (quic_varint:encode(byte_size(ReasonPhrase)))/binary,
      ReasonPhrase/binary>>;

%% CONNECTION_CLOSE (Section 19.19) - application error
encode({connection_close_app, ErrorCode, ReasonPhrase}) ->
    <<(quic_varint:encode(?FRAME_CONNECTION_CLOSE_APP))/binary,
      (quic_varint:encode(ErrorCode))/binary,
      (quic_varint:encode(byte_size(ReasonPhrase)))/binary,
      ReasonPhrase/binary>>;

%% HANDSHAKE_DONE (Section 19.20)
encode(handshake_done) ->
    quic_varint:encode(?FRAME_HANDSHAKE_DONE);

%% DATAGRAM (RFC 9221)
encode({datagram, Data}) ->
    <<(quic_varint:encode(?FRAME_DATAGRAM_LEN))/binary,
      (quic_varint:encode(byte_size(Data)))/binary,
      Data/binary>>.

%% ===================================================================
%% Decoding
%% ===================================================================

%% @doc Decode all frames from a binary payload.
-spec decode_all(binary()) -> {ok, [tuple()]} | {error, term()}.
decode_all(Bin) ->
    decode_all(Bin, []).

decode_all(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
decode_all(Bin, Acc) ->
    case decode(Bin) of
        {ok, Frame, Rest} ->
            decode_all(Rest, [Frame | Acc]);
        {error, _} = Error ->
            Error
    end.

%% @doc Decode a single frame from binary.
%% Returns {ok, Frame, Rest} or {error, Reason}.
-spec decode(binary()) -> {ok, tuple(), binary()} | {error, term()}.

%% PADDING
decode(<<0, Rest/binary>>) ->
    %% Consume contiguous padding
    Rest2 = skip_padding(Rest),
    {ok, padding, Rest2};

decode(Bin) ->
    case quic_varint:decode(Bin) of
        {FrameType, Rest} ->
            decode_frame(FrameType, Rest);
        _ ->
            {error, incomplete_frame_type}
    end.

%% ===================================================================
%% Internal frame decoding by type
%% ===================================================================

%% PING
decode_frame(?FRAME_PING, Rest) ->
    {ok, ping, Rest};

%% ACK
decode_frame(?FRAME_ACK, Bin) ->
    decode_ack(Bin, false);
decode_frame(?FRAME_ACK_ECN, Bin) ->
    decode_ack(Bin, true);

%% RESET_STREAM
decode_frame(?FRAME_RESET_STREAM, Bin) ->
    {StreamId, R1} = quic_varint:decode(Bin),
    {AppErrorCode, R2} = quic_varint:decode(R1),
    {FinalSize, Rest} = quic_varint:decode(R2),
    {ok, {reset_stream, StreamId, AppErrorCode, FinalSize}, Rest};

%% STOP_SENDING
decode_frame(?FRAME_STOP_SENDING, Bin) ->
    {StreamId, R1} = quic_varint:decode(Bin),
    {AppErrorCode, Rest} = quic_varint:decode(R1),
    {ok, {stop_sending, StreamId, AppErrorCode}, Rest};

%% CRYPTO
decode_frame(?FRAME_CRYPTO, Bin) ->
    {Offset, R1} = quic_varint:decode(Bin),
    {Length, R2} = quic_varint:decode(R1),
    <<Data:Length/binary, Rest/binary>> = R2,
    {ok, {crypto, Offset, Data}, Rest};

%% NEW_TOKEN
decode_frame(?FRAME_NEW_TOKEN, Bin) ->
    {Length, R1} = quic_varint:decode(Bin),
    <<Token:Length/binary, Rest/binary>> = R1,
    {ok, {new_token, Token}, Rest};

%% STREAM (0x08-0x0f)
decode_frame(FrameType, Bin) when FrameType >= ?FRAME_STREAM,
                                   FrameType =< ?FRAME_STREAM_END ->
    HasOff = (FrameType band ?STREAM_OFF_BIT) =/= 0,
    HasLen = (FrameType band ?STREAM_LEN_BIT) =/= 0,
    HasFin = (FrameType band ?STREAM_FIN_BIT) =/= 0,
    {StreamId, R1} = quic_varint:decode(Bin),
    {Offset, R2} = case HasOff of
        true -> quic_varint:decode(R1);
        false -> {0, R1}
    end,
    {Data, Rest} = case HasLen of
        true ->
            {Len, R3} = quic_varint:decode(R2),
            <<D:Len/binary, R4/binary>> = R3,
            {D, R4};
        false ->
            %% No length means data extends to end of packet
            {R2, <<>>}
    end,
    {ok, {stream, StreamId, Offset, Data, HasFin}, Rest};

%% MAX_DATA
decode_frame(?FRAME_MAX_DATA, Bin) ->
    {MaxData, Rest} = quic_varint:decode(Bin),
    {ok, {max_data, MaxData}, Rest};

%% MAX_STREAM_DATA
decode_frame(?FRAME_MAX_STREAM_DATA, Bin) ->
    {StreamId, R1} = quic_varint:decode(Bin),
    {MaxStreamData, Rest} = quic_varint:decode(R1),
    {ok, {max_stream_data, StreamId, MaxStreamData}, Rest};

%% MAX_STREAMS
decode_frame(?FRAME_MAX_STREAMS_BIDI, Bin) ->
    {MaxStreams, Rest} = quic_varint:decode(Bin),
    {ok, {max_streams, bidi, MaxStreams}, Rest};
decode_frame(?FRAME_MAX_STREAMS_UNI, Bin) ->
    {MaxStreams, Rest} = quic_varint:decode(Bin),
    {ok, {max_streams, uni, MaxStreams}, Rest};

%% DATA_BLOCKED
decode_frame(?FRAME_DATA_BLOCKED, Bin) ->
    {MaxData, Rest} = quic_varint:decode(Bin),
    {ok, {data_blocked, MaxData}, Rest};

%% STREAM_DATA_BLOCKED
decode_frame(?FRAME_STREAM_DATA_BLOCKED, Bin) ->
    {StreamId, R1} = quic_varint:decode(Bin),
    {MaxStreamData, Rest} = quic_varint:decode(R1),
    {ok, {stream_data_blocked, StreamId, MaxStreamData}, Rest};

%% STREAMS_BLOCKED
decode_frame(?FRAME_STREAMS_BLOCKED_BIDI, Bin) ->
    {MaxStreams, Rest} = quic_varint:decode(Bin),
    {ok, {streams_blocked, bidi, MaxStreams}, Rest};
decode_frame(?FRAME_STREAMS_BLOCKED_UNI, Bin) ->
    {MaxStreams, Rest} = quic_varint:decode(Bin),
    {ok, {streams_blocked, uni, MaxStreams}, Rest};

%% NEW_CONNECTION_ID
decode_frame(?FRAME_NEW_CONNECTION_ID, Bin) ->
    {SeqNum, R1} = quic_varint:decode(Bin),
    {RetirePriorTo, R2} = quic_varint:decode(R1),
    <<CIDLen:8, R3/binary>> = R2,
    <<CID:CIDLen/binary, StatelessResetToken:16/binary, Rest/binary>> = R3,
    {ok, {new_connection_id, SeqNum, RetirePriorTo, CID, StatelessResetToken}, Rest};

%% RETIRE_CONNECTION_ID
decode_frame(?FRAME_RETIRE_CONNECTION_ID, Bin) ->
    {SeqNum, Rest} = quic_varint:decode(Bin),
    {ok, {retire_connection_id, SeqNum}, Rest};

%% PATH_CHALLENGE
decode_frame(?FRAME_PATH_CHALLENGE, <<Data:8/binary, Rest/binary>>) ->
    {ok, {path_challenge, Data}, Rest};

%% PATH_RESPONSE
decode_frame(?FRAME_PATH_RESPONSE, <<Data:8/binary, Rest/binary>>) ->
    {ok, {path_response, Data}, Rest};

%% CONNECTION_CLOSE (transport)
decode_frame(?FRAME_CONNECTION_CLOSE, Bin) ->
    {ErrorCode, R1} = quic_varint:decode(Bin),
    {FrameType, R2} = quic_varint:decode(R1),
    {ReasonLen, R3} = quic_varint:decode(R2),
    <<ReasonPhrase:ReasonLen/binary, Rest/binary>> = R3,
    {ok, {connection_close, ErrorCode, FrameType, ReasonPhrase}, Rest};

%% CONNECTION_CLOSE (application)
decode_frame(?FRAME_CONNECTION_CLOSE_APP, Bin) ->
    {ErrorCode, R1} = quic_varint:decode(Bin),
    {ReasonLen, R2} = quic_varint:decode(R1),
    <<ReasonPhrase:ReasonLen/binary, Rest/binary>> = R2,
    {ok, {connection_close_app, ErrorCode, ReasonPhrase}, Rest};

%% HANDSHAKE_DONE
decode_frame(?FRAME_HANDSHAKE_DONE, Rest) ->
    {ok, handshake_done, Rest};

%% DATAGRAM (RFC 9221)
decode_frame(?FRAME_DATAGRAM, Bin) ->
    %% No length - extends to end of packet
    {ok, {datagram, Bin}, <<>>};
decode_frame(?FRAME_DATAGRAM_LEN, Bin) ->
    {Length, R1} = quic_varint:decode(Bin),
    <<Data:Length/binary, Rest/binary>> = R1,
    {ok, {datagram, Data}, Rest};

decode_frame(Unknown, _Bin) ->
    {error, {unknown_frame_type, Unknown}}.

%% ===================================================================
%% Internal helpers
%% ===================================================================

skip_padding(<<0, Rest/binary>>) -> skip_padding(Rest);
skip_padding(Rest) -> Rest.

encode_ack(Type, LargestAcked, AckDelay, Ranges, ECNSuffix) ->
    %% Ranges is a list of {Gap, AckRange} pairs after the first range
    %% First element of Ranges is the first ack range
    [FirstAckRange | GapRanges] = Ranges,
    AckRangeCount = length(GapRanges),
    RangesBin = encode_ack_ranges(GapRanges),
    <<(quic_varint:encode(Type))/binary,
      (quic_varint:encode(LargestAcked))/binary,
      (quic_varint:encode(AckDelay))/binary,
      (quic_varint:encode(AckRangeCount))/binary,
      (quic_varint:encode(FirstAckRange))/binary,
      RangesBin/binary,
      ECNSuffix/binary>>.

encode_ack_ranges([]) -> <<>>;
encode_ack_ranges([{Gap, AckRange} | Rest]) ->
    <<(quic_varint:encode(Gap))/binary,
      (quic_varint:encode(AckRange))/binary,
      (encode_ack_ranges(Rest))/binary>>.

decode_ack(Bin, HasECN) ->
    {LargestAcked, R1} = quic_varint:decode(Bin),
    {AckDelay, R2} = quic_varint:decode(R1),
    {AckRangeCount, R3} = quic_varint:decode(R2),
    {FirstAckRange, R4} = quic_varint:decode(R3),
    {GapRanges, R5} = decode_ack_ranges(AckRangeCount, R4),
    Ranges = [FirstAckRange | GapRanges],
    case HasECN of
        false ->
            {ok, {ack, LargestAcked, AckDelay, Ranges}, R5};
        true ->
            {ECT0, R6} = quic_varint:decode(R5),
            {ECT1, R7} = quic_varint:decode(R6),
            {ECNCE, Rest} = quic_varint:decode(R7),
            {ok, {ack_ecn, LargestAcked, AckDelay, Ranges, {ECT0, ECT1, ECNCE}}, Rest}
    end.

decode_ack_ranges(0, Rest) -> {[], Rest};
decode_ack_ranges(N, Bin) ->
    {Gap, R1} = quic_varint:decode(Bin),
    {AckRange, R2} = quic_varint:decode(R1),
    {More, Rest} = decode_ack_ranges(N - 1, R2),
    {[{Gap, AckRange} | More], Rest}.
