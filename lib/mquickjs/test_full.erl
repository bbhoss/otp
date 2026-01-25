-module(test_full).
-export([run/0]).

run() ->
    io:format("~n=== MQuickJS Full Integration Test ===~n~n"),

    %% Start the JavaScript engine
    io:format("Starting mquickjs server...~n"),
    case mquickjs:start_link() of
        {ok, Pid} ->
            io:format("Server started with pid: ~p~n~n", [Pid]),
            run_tests(Pid);
        {error, Reason} ->
            io:format("Failed to start server: ~p~n", [Reason]),
            error
    end.

run_tests(Pid) ->
    Tests = [
        {"Simple arithmetic: 21 + 21", <<"21 + 21">>, fun(R) -> R =:= 42 end},
        {"Multiplication: 6 * 7", <<"6 * 7">>, fun(R) -> R =:= 42 end},
        {"String", <<"'hello world'">>, fun(R) -> R =:= <<"hello world">> end},
        {"Boolean true", <<"true">>, fun(R) -> R =:= true end},
        {"Boolean false", <<"false">>, fun(R) -> R =:= false end},
        {"Comparison", <<"10 > 5">>, fun(R) -> R =:= true end},
        {"Undefined", <<"undefined">>, fun(R) -> R =:= undefined end},
        {"Null", <<"null">>, fun(R) -> R =:= null end},
        {"Float", <<"3.14159">>, fun(R) -> is_float(R) andalso R > 3.14 andalso R < 3.15 end},
        {"Array to string", <<"[1,2,3].join('-')">>, fun(R) -> R =:= <<"1-2-3">> end},
        {"Object property", <<"var o = {x: 42}; o.x">>, fun(R) -> R =:= 42 end},
        {"Function call", <<"function f(a,b) { return a + b; } f(10, 32)">>, fun(R) -> R =:= 42 end},
        {"Fibonacci", <<"function fib(n) { if (n <= 1) return n; return fib(n-1) + fib(n-2); } fib(10)">>, fun(R) -> R =:= 55 end},
        {"Math.sqrt", <<"Math.sqrt(144)">>, fun(R) -> R =:= 12 orelse R =:= 12.0 end},
        {"Math.floor", <<"Math.floor(3.7)">>, fun(R) -> R =:= 3 end},
        {"String concat", <<"'Hello' + ' ' + 'World'">>, fun(R) -> R =:= <<"Hello World">> end},
        {"JSON stringify", <<"JSON.stringify({a: 1, b: 2})">>, fun(R) -> R =:= <<"{\"a\":1,\"b\":2}">> end}
    ],

    {Passed, Failed} = run_test_list(Pid, Tests, 0, 0),

    io:format("~n--- Test Results ---~n"),
    io:format("Passed: ~p~n", [Passed]),
    io:format("Failed: ~p~n", [Failed]),

    %% Test console output
    io:format("~n--- Console Output Test ---~n"),
    mquickjs:eval(Pid, <<"print('Hello from JavaScript!')">>),
    case mquickjs:get_output(Pid) of
        {ok, Output} ->
            io:format("Captured output: ~p~n", [Output]);
        {error, E} ->
            io:format("Error getting output: ~p~n", [E])
    end,

    %% Test error handling
    io:format("~n--- Error Handling Test ---~n"),
    case mquickjs:eval(Pid, <<"this is invalid syntax {{{">>)  of
        {error, _} -> io:format("Syntax error correctly detected~n");
        {ok, V} -> io:format("FAIL: Expected error, got ~p~n", [V])
    end,

    %% Test GC
    io:format("~n--- GC Test ---~n"),
    case mquickjs:gc(Pid) of
        ok -> io:format("GC completed successfully~n");
        {error, E2} -> io:format("GC error: ~p~n", [E2])
    end,

    %% Cleanup
    io:format("~nStopping server...~n"),
    mquickjs:stop(Pid),
    io:format("~n=== All tests completed ===~n"),
    ok.

run_test_list(_Pid, [], Passed, Failed) ->
    {Passed, Failed};
run_test_list(Pid, [{Name, Code, Check} | Rest], Passed, Failed) ->
    io:format("~s: ", [Name]),
    case mquickjs:eval(Pid, Code) of
        {ok, Result} ->
            case Check(Result) of
                true ->
                    io:format("~p (PASS)~n", [Result]),
                    run_test_list(Pid, Rest, Passed + 1, Failed);
                false ->
                    io:format("~p (FAIL - unexpected value)~n", [Result]),
                    run_test_list(Pid, Rest, Passed, Failed + 1)
            end;
        {error, Error} ->
            io:format("ERROR: ~p~n", [Error]),
            run_test_list(Pid, Rest, Passed, Failed + 1)
    end.
