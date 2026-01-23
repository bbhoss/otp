%% Test script for gen_wasmserver with Rust counter WASM module
-module(test_server).
-export([run/0]).

run() ->
    io:format("~n"),
    io:format("================================================================~n"),
    io:format("    gen_wasmserver Test with Rust Counter WASM Module~n"),
    io:format("================================================================~n~n"),

    %% Load the WASM binary
    WasmFile = "rust_counter.wasm",
    io:format("1. Loading WASM binary from ~s...~n", [WasmFile]),
    case file:read_file(WasmFile) of
        {ok, WasmBinary} ->
            io:format("   [OK] Loaded ~p bytes~n~n", [byte_size(WasmBinary)]),
            test_with_wasm(WasmBinary);
        {error, Reason} ->
            io:format("   [FAIL] Failed to load: ~p~n", [Reason]),
            io:format("   Using minimal WASM header for stub testing...~n~n"),
            %% Use minimal WASM header for stub implementation
            WasmBinary = <<0,97,115,109,1,0,0,0>>,
            test_with_wasm(WasmBinary)
    end.

test_with_wasm(WasmBinary) ->
    %% Start the server with initial value of 0
    io:format("2. Starting gen_wasmserver with initial counter value: 0~n"),
    case gen_wasmserver:start_link(WasmBinary, 0, []) of
        {ok, Pid} ->
            io:format("   [OK] Server started with PID: ~p~n~n", [Pid]),
            run_tests(Pid);
        {error, Reason} ->
            io:format("   [FAIL] Failed to start: ~p~n", [Reason])
    end.

run_tests(Pid) ->
    io:format("3. Testing gen_wasmserver operations:~n~n"),

    %% Test: Get current value
    io:format("   [GET] Requesting current counter value...~n"),
    Reply1 = gen_wasmserver:call(Pid, get),
    io:format("         Response: ~p~n~n", [Reply1]),

    %% Test: Increment
    io:format("   [INCREMENT] Sending increment command...~n"),
    ok = gen_wasmserver:cast(Pid, increment),
    timer:sleep(50),  %% Give time for cast to process
    Reply2 = gen_wasmserver:call(Pid, get),
    io:format("         After increment, value: ~p~n~n", [Reply2]),

    %% Test: Increment again
    io:format("   [INCREMENT] Sending another increment...~n"),
    ok = gen_wasmserver:cast(Pid, increment),
    timer:sleep(50),
    Reply3 = gen_wasmserver:call(Pid, get),
    io:format("         After increment, value: ~p~n~n", [Reply3]),

    %% Test: Decrement
    io:format("   [DECREMENT] Sending decrement command...~n"),
    ok = gen_wasmserver:cast(Pid, decrement),
    timer:sleep(50),
    Reply4 = gen_wasmserver:call(Pid, get),
    io:format("         After decrement, value: ~p~n~n", [Reply4]),

    %% Test: Set value
    io:format("   [SET] Setting counter to 100...~n"),
    Reply5 = gen_wasmserver:call(Pid, {set, 100}),
    io:format("         Response: ~p~n", [Reply5]),
    Reply6 = gen_wasmserver:call(Pid, get),
    io:format("         Current value: ~p~n~n", [Reply6]),

    %% Test: Add value
    io:format("   [ADD] Adding 50 to counter...~n"),
    Reply7 = gen_wasmserver:call(Pid, {add, 50}),
    io:format("         Response: ~p~n~n", [Reply7]),

    %% Test: Reset
    io:format("   [RESET] Resetting counter to 0...~n"),
    ok = gen_wasmserver:cast(Pid, reset),
    timer:sleep(50),
    Reply8 = gen_wasmserver:call(Pid, get),
    io:format("         After reset, value: ~p~n~n", [Reply8]),

    %% Stop the server
    io:format("4. Stopping server...~n"),
    gen_wasmserver:stop(Pid),
    io:format("   [OK] Server stopped~n~n"),

    io:format("================================================================~n"),
    io:format("    All Tests Completed!~n"),
    io:format("~n"),
    io:format("    NOTE: Currently using STUB implementation (echoes requests).~n"),
    io:format("    For real WASM execution, build the wasm_runtime_nif with~n"),
    io:format("    wasmtime or wasmer integration.~n"),
    io:format("================================================================~n~n"),
    ok.
