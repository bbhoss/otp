%%
%% Minimal JSON encode/decode for the QUIC chat example.
%% Only supports the subset needed: flat maps with binary keys/values and lists of binaries.
%%

-module(quic_chat_json).

-export([encode/1, decode/1]).

%% ===================================================================
%% Encode
%% ===================================================================

encode(Map) when is_map(Map) ->
    Pairs = maps:fold(fun(K, V, Acc) ->
        Entry = [encode_string(K), <<":">>, encode_value(V)],
        case Acc of
            [] -> [Entry];
            _ -> [Entry, <<",">> | Acc]
        end
    end, [], Map),
    iolist_to_binary([<<"{">>, Pairs, <<"}">>]);
encode(List) when is_list(List) ->
    encode_array(List).

encode_value(V) when is_binary(V) -> encode_string(V);
encode_value(V) when is_integer(V) -> integer_to_binary(V);
encode_value(V) when is_atom(V) -> encode_string(atom_to_binary(V, utf8));
encode_value(V) when is_list(V) -> encode_array(V);
encode_value(V) when is_map(V) -> encode(V).

encode_string(B) when is_binary(B) ->
    %% Simple escaping - just escape quotes and backslashes
    Escaped = binary:replace(
        binary:replace(B, <<"\\">>, <<"\\\\">>, [global]),
        <<"\"">>, <<"\\\"">>, [global]),
    <<"\"", Escaped/binary, "\"">>.

encode_array(List) ->
    Items = lists:join(<<",">>, [encode_value(V) || V <- List]),
    iolist_to_binary([<<"[">>, Items, <<"]">>]).

%% ===================================================================
%% Decode
%% ===================================================================

decode(Bin) when is_binary(Bin) ->
    {Value, _Rest} = decode_value(skip_ws(Bin)),
    Value.

decode_value(<<${, Rest/binary>>) -> decode_object(skip_ws(Rest), #{});
decode_value(<<$[, Rest/binary>>) -> decode_array(skip_ws(Rest), []);
decode_value(<<$", Rest/binary>>) -> decode_string(Rest, <<>>);
decode_value(<<$t, $r, $u, $e, Rest/binary>>) -> {true, Rest};
decode_value(<<$f, $a, $l, $s, $e, Rest/binary>>) -> {false, Rest};
decode_value(<<$n, $u, $l, $l, Rest/binary>>) -> {null, Rest};
decode_value(Bin) -> decode_number(Bin, <<>>).

decode_object(<<$}, Rest/binary>>, Acc) -> {Acc, Rest};
decode_object(<<$", Rest/binary>>, Acc) ->
    {Key, R1} = decode_string(Rest, <<>>),
    <<$:, R2/binary>> = skip_ws(R1),
    {Value, R3} = decode_value(skip_ws(R2)),
    R4 = skip_ws(R3),
    case R4 of
        <<$,, R5/binary>> -> decode_object(skip_ws(R5), Acc#{Key => Value});
        <<$}, R5/binary>> -> {Acc#{Key => Value}, R5}
    end.

decode_array(<<$], Rest/binary>>, Acc) -> {lists:reverse(Acc), Rest};
decode_array(Bin, Acc) ->
    {Value, R1} = decode_value(Bin),
    R2 = skip_ws(R1),
    case R2 of
        <<$,, R3/binary>> -> decode_array(skip_ws(R3), [Value | Acc]);
        <<$], R3/binary>> -> {lists:reverse([Value | Acc]), R3}
    end.

decode_string(<<$", Rest/binary>>, Acc) -> {Acc, Rest};
decode_string(<<$\\, $", Rest/binary>>, Acc) -> decode_string(Rest, <<Acc/binary, $">>);
decode_string(<<$\\, $\\, Rest/binary>>, Acc) -> decode_string(Rest, <<Acc/binary, $\\>>);
decode_string(<<$\\, $n, Rest/binary>>, Acc) -> decode_string(Rest, <<Acc/binary, $\n>>);
decode_string(<<$\\, $t, Rest/binary>>, Acc) -> decode_string(Rest, <<Acc/binary, $\t>>);
decode_string(<<$\\, $/, Rest/binary>>, Acc) -> decode_string(Rest, <<Acc/binary, $/>>);
decode_string(<<C, Rest/binary>>, Acc) -> decode_string(Rest, <<Acc/binary, C>>).

decode_number(<<C, Rest/binary>>, Acc)
  when C >= $0, C =< $9; C =:= $-; C =:= $.; C =:= $e; C =:= $E; C =:= $+ ->
    decode_number(Rest, <<Acc/binary, C>>);
decode_number(Rest, Acc) ->
    {binary_to_integer(Acc), Rest}.

skip_ws(<<$ , Rest/binary>>) -> skip_ws(Rest);
skip_ws(<<$\t, Rest/binary>>) -> skip_ws(Rest);
skip_ws(<<$\n, Rest/binary>>) -> skip_ws(Rest);
skip_ws(<<$\r, Rest/binary>>) -> skip_ws(Rest);
skip_ws(Bin) -> Bin.
