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

%% QUIC Stream Management (RFC 9000, Section 2-3)
%%
%% Stream IDs use the 2 least significant bits:
%%   0x00: Client-initiated, bidirectional
%%   0x01: Server-initiated, bidirectional
%%   0x02: Client-initiated, unidirectional
%%   0x03: Server-initiated, unidirectional

-module(quic_stream).

-include("quic.hrl").

-export([
    new/3,
    send/2,
    receive_data/4,
    read/1,
    read/2,
    close_send/1,
    is_local/2,
    is_bidirectional/1,
    stream_type/1,
    next_stream_id/2,
    add_recv_waiter/2
]).

%% ===================================================================
%% Stream Creation
%% ===================================================================

%% @doc Create a new stream.
-spec new(non_neg_integer(), non_neg_integer(), non_neg_integer()) -> #quic_stream{}.
new(StreamId, MaxSendData, MaxRecvData) ->
    #quic_stream{
        id = StreamId,
        send_state = ready,
        recv_state = recv,
        send_buffer = <<>>,
        recv_buffer = #{},
        send_offset = 0,
        recv_offset = 0,
        max_send_data = MaxSendData,
        max_recv_data = MaxRecvData,
        recv_data_size = 0,
        fin_sent = false,
        fin_received = false,
        recv_waiters = []
    }.

%% ===================================================================
%% Sending
%% ===================================================================

%% @doc Buffer data for sending on a stream.
%% Returns STREAM frames to be sent and the updated stream.
-spec send(#quic_stream{}, binary()) ->
    {ok, [tuple()], #quic_stream{}} | {error, term()}.
send(#quic_stream{send_state = S} = Stream, _Data)
  when S =:= data_sent; S =:= reset_sent; S =:= reset_recvd ->
    {error, stream_closed};
send(#quic_stream{} = Stream, Data) ->
    #quic_stream{
        id = StreamId,
        send_offset = Offset,
        max_send_data = MaxSend
    } = Stream,

    %% Check flow control
    Available = MaxSend - Offset,
    SendLen = min(byte_size(Data), Available),
    case SendLen of
        0 when byte_size(Data) > 0 ->
            %% Flow control blocked
            {error, flow_control_blocked};
        _ ->
            <<SendData:SendLen/binary, _Rest/binary>> = Data,
            Frame = {stream, StreamId, Offset, SendData, false},
            NewStream = Stream#quic_stream{
                send_offset = Offset + SendLen,
                send_state = send
            },
            {ok, [Frame], NewStream}
    end.

%% @doc Mark the stream as FIN sent.
-spec close_send(#quic_stream{}) -> {tuple(), #quic_stream{}}.
close_send(#quic_stream{id = StreamId, send_offset = Offset} = Stream) ->
    Frame = {stream, StreamId, Offset, <<>>, true},
    {Frame, Stream#quic_stream{fin_sent = true, send_state = data_sent}}.

%% ===================================================================
%% Receiving
%% ===================================================================

%% @doc Process received data for a stream.
-spec receive_data(#quic_stream{}, binary(), non_neg_integer(), boolean()) ->
    {ok, #quic_stream{}} | {error, term()}.
receive_data(#quic_stream{recv_state = RS} = _Stream, _Data, _Offset, _Fin)
  when RS =:= data_read; RS =:= reset_recvd ->
    {error, stream_closed};
receive_data(#quic_stream{} = Stream, Data, Offset, Fin) ->
    %% Store data in the receive buffer keyed by offset
    RecvBuf = Stream#quic_stream.recv_buffer,
    NewRecvBuf = case byte_size(Data) > 0 of
        true -> RecvBuf#{Offset => Data};
        false -> RecvBuf
    end,
    NewRecvDataSize = Stream#quic_stream.recv_data_size + byte_size(Data),

    NewStream = Stream#quic_stream{
        recv_buffer = NewRecvBuf,
        recv_data_size = NewRecvDataSize,
        fin_received = Fin orelse Stream#quic_stream.fin_received,
        recv_state = case Fin of
            true -> size_known;
            false -> Stream#quic_stream.recv_state
        end
    },
    {ok, NewStream}.

%% @doc Read contiguous data from the receive buffer.
%% Returns as much contiguous data as available starting from recv_offset.
-spec read(#quic_stream{}) -> {binary(), #quic_stream{}}.
read(Stream) ->
    read(Stream, 0).

%% @doc Read up to Length bytes (0 = all available).
-spec read(#quic_stream{}, non_neg_integer()) -> {binary(), #quic_stream{}}.
read(#quic_stream{recv_offset = Offset, recv_buffer = Buf} = Stream, MaxLen) ->
    {Data, NewOffset, NewBuf} = read_contiguous(Offset, Buf, MaxLen),
    FinReached = NewBuf =:= #{} andalso Stream#quic_stream.fin_received,
    NewRecvState = case FinReached of
        true -> data_read;
        false -> Stream#quic_stream.recv_state
    end,
    {Data, Stream#quic_stream{
        recv_offset = NewOffset,
        recv_buffer = NewBuf,
        recv_state = NewRecvState
    }}.

%% ===================================================================
%% Stream ID Helpers
%% ===================================================================

%% @doc Check if a stream ID is locally initiated.
-spec is_local(non_neg_integer(), client | server) -> boolean().
is_local(StreamId, client) -> (StreamId band 1) =:= 0;
is_local(StreamId, server) -> (StreamId band 1) =:= 1.

%% @doc Check if a stream is bidirectional.
-spec is_bidirectional(non_neg_integer()) -> boolean().
is_bidirectional(StreamId) -> (StreamId band 2) =:= 0.

%% @doc Get the stream type.
-spec stream_type(non_neg_integer()) ->
    {client | server, bidirectional | unidirectional}.
stream_type(StreamId) ->
    Initiator = case StreamId band 1 of 0 -> client; 1 -> server end,
    Direction = case StreamId band 2 of 0 -> bidirectional; 2 -> unidirectional end,
    {Initiator, Direction}.

%% @doc Get the next stream ID for a given role and type.
-spec next_stream_id(client | server, bidirectional | unidirectional) ->
    non_neg_integer().
next_stream_id(client, bidirectional) -> 0;
next_stream_id(server, bidirectional) -> 1;
next_stream_id(client, unidirectional) -> 2;
next_stream_id(server, unidirectional) -> 3.

%% ===================================================================
%% Waiter Management
%% ===================================================================

%% @doc Add a process waiting for data on this stream.
-spec add_recv_waiter(#quic_stream{}, {pid(), reference()}) -> #quic_stream{}.
add_recv_waiter(Stream, Waiter) ->
    Stream#quic_stream{
        recv_waiters = Stream#quic_stream.recv_waiters ++ [Waiter]
    }.

%% ===================================================================
%% Internal
%% ===================================================================

read_contiguous(Offset, Buf, MaxLen) ->
    read_contiguous(Offset, Buf, MaxLen, []).

read_contiguous(Offset, Buf, MaxLen, Acc) ->
    case maps:take(Offset, Buf) of
        {Data, NewBuf} ->
            DataLen = byte_size(Data),
            case MaxLen > 0 andalso iolist_size(Acc) + DataLen > MaxLen of
                true ->
                    %% Would exceed max - take partial
                    Take = MaxLen - iolist_size(Acc),
                    <<Taken:Take/binary, Remaining/binary>> = Data,
                    FinalBuf = NewBuf#{(Offset + Take) => Remaining},
                    {iolist_to_binary(lists:reverse([Taken | Acc])),
                     Offset + Take, FinalBuf};
                false ->
                    read_contiguous(Offset + DataLen, NewBuf, MaxLen,
                                    [Data | Acc])
            end;
        error ->
            {iolist_to_binary(lists:reverse(Acc)), Offset, Buf}
    end.
