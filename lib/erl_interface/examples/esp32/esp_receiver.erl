-module(esp_receiver).
-export([start/0, loop/0]).

start() ->
    io:format("Starting esp_handler process...~n"),
    Pid = spawn(?MODULE, loop, []),
    register(esp_handler, Pid),
    io:format("esp_handler registered (pid: ~p)~n", [Pid]),
    io:format("Waiting for messages from ESP32...~n~n"),
    Pid.

loop() ->
    receive
        {hello_from_esp32, FromPid} ->
            io:format("~n========================================~n"),
            io:format("*** RECEIVED FROM ESP32! ***~n"),
            io:format("Message: {hello_from_esp32, ~p}~n", [FromPid]),
            io:format("========================================~n~n"),
            loop();
        Other ->
            io:format("Received: ~p~n", [Other]),
            loop()
    after 120000 ->
        io:format("Timeout waiting for ESP32~n"),
        ok
    end.
