%% @doc ESP32 Ping-Pong Handler
%%
%% This module provides a simple ping-pong handler for testing communication
%% between an ESP32 C-node and an Erlang node. It receives {ping, Number, Pid}
%% messages and replies with {pong, Number}.
%%
%% Usage:
%%   1. Compile: erlc esp_handler.erl
%%   2. Start Erlang node:
%%      erl -sname erlhost -setcookie testcookie \
%%          -kernel inet_dist_listen_min 9000 inet_dist_listen_max 9000 \
%%          -noshell -s esp_handler start
%%   3. Run the ESP32 demo (or QEMU emulation)

-module(esp_handler).
-export([start/0, loop/0]).

%% @doc Start the ping-pong handler
%% Spawns a process and registers it as 'esp_handler'
start() ->
    io:format("Starting ESP32 ping-pong handler...~n"),
    register(esp_handler, spawn(?MODULE, loop, [])),
    io:format("Handler registered as 'esp_handler'~n"),
    io:format("Waiting for ping messages from ESP32...~n"),
    ok.

%% @doc Main receive loop
%% Handles {ping, Number, Pid} messages and replies with {pong, Number}
loop() ->
    receive
        {ping, Number, Pid} when is_integer(Number) ->
            io:format("Received: {ping, ~p} from ~p~n", [Number, Pid]),
            io:format("Sending:  {pong, ~p}~n", [Number]),
            Pid ! {pong, Number},
            loop();
        Other ->
            io:format("Received unknown: ~p~n", [Other]),
            loop()
    end.
