%%
%% Trading Simulation - Multiple concurrent traders on one JS instance
%%
%% This demonstrates multiple Erlang processes competing to trade stocks,
%% with all state and logic managed by a single JavaScript instance.
%%
-module(trading_simulation).
-export([run/0, run/1]).

run() ->
    run(5).  % Default: 5 traders

run(NumTraders) ->
    io:format("~n========================================~n"),
    io:format("   Stock Exchange Trading Simulation~n"),
    io:format("========================================~n~n"),

    %% Start the exchange
    io:format("Starting exchange...~n"),
    {ok, Exchange} = stock_exchange:start_link(),

    %% Show initial prices
    io:format("~nInitial stock prices:~n"),
    {ok, Prices} = stock_exchange:get_all_prices(Exchange),
    io:format("~s~n~n", [Prices]),

    %% Register traders and give them starting capital
    Traders = [list_to_atom("trader_" ++ integer_to_list(I)) || I <- lists:seq(1, NumTraders)],

    io:format("Registering ~p traders...~n", [NumTraders]),
    lists:foreach(fun(Trader) ->
        {ok, _} = stock_exchange:register_trader(Exchange, Trader),
        {ok, _} = stock_exchange:deposit(Exchange, Trader, 10000),  % $10,000 each
        io:format("  ~p registered with $10,000~n", [Trader])
    end, Traders),

    %% Run the simulation
    io:format("~n--- Starting Trading Session ---~n~n"),

    %% Each trader runs in their own process
    Self = self(),
    _TraderPids = lists:map(fun(Trader) ->
        spawn_link(fun() -> trader_loop(Exchange, Trader, 10, Self) end)
    end, Traders),

    %% Wait for all traders to finish
    wait_for_traders(NumTraders),

    %% Collect and display console output from JS
    io:format("~n--- Trade Log ---~n"),
    {ok, Output} = stock_exchange:get_trade_log(Exchange),
    io:format("~s~n", [Output]),

    %% Show final results
    io:format("~n--- Final Results ---~n~n"),

    %% Market stats
    {ok, Stats} = stock_exchange:get_market_stats(Exchange),
    io:format("Market Statistics: ~s~n~n", [Stats]),

    %% Final prices
    io:format("Final Prices:~n"),
    {ok, FinalPrices} = stock_exchange:get_all_prices(Exchange),
    io:format("~s~n~n", [FinalPrices]),

    %% Each trader's portfolio
    io:format("Trader Portfolios:~n"),
    lists:foreach(fun(Trader) ->
        {ok, Portfolio} = stock_exchange:get_portfolio(Exchange, Trader),
        io:format("  ~p: ~s~n", [Trader, Portfolio])
    end, Traders),

    %% Stop the exchange
    stock_exchange:stop(Exchange),

    io:format("~n========================================~n"),
    io:format("         Simulation Complete~n"),
    io:format("========================================~n~n"),
    ok.

%% Trader behavior - makes random trades
trader_loop(_Exchange, Trader, 0, Parent) ->
    Parent ! {trader_done, Trader};
trader_loop(Exchange, Trader, RoundsLeft, Parent) ->
    %% Random delay to simulate thinking
    timer:sleep(rand:uniform(100)),

    %% Pick a random action
    Action = rand:uniform(3),
    Symbol = pick_random_symbol(),

    case Action of
        1 ->
            %% Buy some shares
            Qty = rand:uniform(10),
            case stock_exchange:place_order(Exchange, Trader, Symbol, buy, Qty) of
                {ok, _} -> ok;
                {error, _} -> ok  % Insufficient funds is ok
            end;
        2 ->
            %% Sell some shares (if we have any)
            Qty = rand:uniform(5),
            case stock_exchange:place_order(Exchange, Trader, Symbol, sell, Qty) of
                {ok, _} -> ok;
                {error, _} -> ok  % No shares is ok
            end;
        3 ->
            %% Just check portfolio
            stock_exchange:get_portfolio(Exchange, Trader)
    end,

    trader_loop(Exchange, Trader, RoundsLeft - 1, Parent).

pick_random_symbol() ->
    Symbols = ["AAPL", "GOOG", "MSFT", "AMZN", "TSLA"],
    lists:nth(rand:uniform(length(Symbols)), Symbols).

wait_for_traders(0) -> ok;
wait_for_traders(N) when N > 0 ->
    receive
        {trader_done, _Trader} ->
            wait_for_traders(N - 1)
    after 10000 ->
        io:format("Timeout waiting for traders (remaining: ~p)~n", [N])
    end.
