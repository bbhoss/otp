%%
%% Stock Exchange - A trading simulation using MQuickJS
%%
%% This module demonstrates using a single JavaScript instance to manage
%% persistent state across multiple Erlang callers. All trading logic
%% (order matching, portfolio management, price discovery) runs in JavaScript.
%%
-module(stock_exchange).
-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1, stop/1]).
-export([register_trader/2, get_portfolio/2, deposit/3, withdraw/3]).
-export([place_order/5, cancel_order/3]).
-export([get_order_book/2, get_price/2, get_market_stats/1]).
-export([get_trade_history/2, get_all_prices/1]).
-export([get_trade_log/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    js_pid :: pid()
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    start_link([]).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

stop(Exchange) ->
    gen_server:stop(Exchange).

%% Register a new trader with initial cash
register_trader(Exchange, TraderId) ->
    gen_server:call(Exchange, {register_trader, TraderId}).

%% Get a trader's portfolio (cash + holdings)
get_portfolio(Exchange, TraderId) ->
    gen_server:call(Exchange, {get_portfolio, TraderId}).

%% Deposit cash to a trader's account
deposit(Exchange, TraderId, Amount) ->
    gen_server:call(Exchange, {deposit, TraderId, Amount}).

%% Withdraw cash from a trader's account
withdraw(Exchange, TraderId, Amount) ->
    gen_server:call(Exchange, {withdraw, TraderId, Amount}).

%% Place a buy or sell order
%% Side = buy | sell
%% Type = market | {limit, Price}
place_order(Exchange, TraderId, Symbol, Side, Quantity) when Side =:= buy; Side =:= sell ->
    gen_server:call(Exchange, {place_order, TraderId, Symbol, Side, Quantity}).

%% Cancel an open order
cancel_order(Exchange, TraderId, OrderId) ->
    gen_server:call(Exchange, {cancel_order, TraderId, OrderId}).

%% Get the order book for a symbol
get_order_book(Exchange, Symbol) ->
    gen_server:call(Exchange, {get_order_book, Symbol}).

%% Get the current price for a symbol
get_price(Exchange, Symbol) ->
    gen_server:call(Exchange, {get_price, Symbol}).

%% Get market statistics
get_market_stats(Exchange) ->
    gen_server:call(Exchange, get_market_stats).

%% Get trade history for a trader
get_trade_history(Exchange, TraderId) ->
    gen_server:call(Exchange, {get_trade_history, TraderId}).

%% Get all current prices
get_all_prices(Exchange) ->
    gen_server:call(Exchange, get_all_prices).

%% Get the trade log (console output from JS)
get_trade_log(Exchange) ->
    gen_server:call(Exchange, get_trade_log).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Opts) ->
    %% Start the JavaScript engine
    {ok, JsPid} = mquickjs:start_link([{mem_size, 512}]),

    %% Initialize the trading engine in JavaScript
    case init_trading_engine(JsPid) of
        ok ->
            {ok, #state{js_pid = JsPid}};
        {error, Reason} ->
            mquickjs:stop(JsPid),
            {stop, Reason}
    end.

handle_call({register_trader, TraderId}, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.registerTrader", [TraderId]),
    {reply, Result, State};

handle_call({get_portfolio, TraderId}, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.getPortfolio", [TraderId]),
    {reply, Result, State};

handle_call({deposit, TraderId, Amount}, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.deposit", [TraderId, Amount]),
    {reply, Result, State};

handle_call({withdraw, TraderId, Amount}, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.withdraw", [TraderId, Amount]),
    {reply, Result, State};

handle_call({place_order, TraderId, Symbol, Side, Quantity}, _From, State) ->
    SideStr = atom_to_list(Side),
    Result = js_call(State#state.js_pid, "exchange.placeOrder",
                     [TraderId, Symbol, SideStr, Quantity]),
    {reply, Result, State};

handle_call({cancel_order, TraderId, OrderId}, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.cancelOrder", [TraderId, OrderId]),
    {reply, Result, State};

handle_call({get_order_book, Symbol}, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.getOrderBook", [Symbol]),
    {reply, Result, State};

handle_call({get_price, Symbol}, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.getPrice", [Symbol]),
    {reply, Result, State};

handle_call(get_market_stats, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.getMarketStats", []),
    {reply, Result, State};

handle_call({get_trade_history, TraderId}, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.getTradeHistory", [TraderId]),
    {reply, Result, State};

handle_call(get_all_prices, _From, State) ->
    Result = js_call(State#state.js_pid, "exchange.getAllPrices", []),
    {reply, Result, State};

handle_call(get_trade_log, _From, State) ->
    Result = mquickjs:get_output(State#state.js_pid),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{js_pid = JsPid}) ->
    mquickjs:stop(JsPid),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% Call a JavaScript function with arguments
js_call(JsPid, FuncName, Args) ->
    %% Build the function call
    ArgsJson = args_to_json(Args),
    Code = iolist_to_binary([FuncName, "(", ArgsJson, ")"]),
    case mquickjs:eval(JsPid, Code) of
        {ok, Result} ->
            parse_result(Result);
        {error, _} = Error ->
            Error
    end.

%% Convert Erlang args to JSON-ish JavaScript arguments
args_to_json([]) -> "";
args_to_json(Args) ->
    lists:join(",", [arg_to_js(A) || A <- Args]).

arg_to_js(A) when is_integer(A) -> integer_to_list(A);
arg_to_js(A) when is_float(A) -> float_to_list(A, [{decimals, 2}]);
arg_to_js(A) when is_atom(A) -> ["\"", atom_to_list(A), "\""];
arg_to_js(A) when is_binary(A) -> ["\"", A, "\""];
arg_to_js(A) when is_list(A) -> ["\"", A, "\""].

%% Parse JavaScript result back to Erlang
parse_result(<<"ok">>) -> ok;
parse_result(<<"error:", Rest/binary>>) -> {error, Rest};
parse_result(Result) when is_binary(Result) ->
    %% Try to parse as JSON
    case Result of
        <<"{", _/binary>> -> {ok, parse_json_object(Result)};
        <<"[", _/binary>> -> {ok, parse_json_array(Result)};
        _ -> {ok, Result}
    end;
parse_result(Result) -> {ok, Result}.

%% Simple JSON object parser (returns as binary for simplicity)
parse_json_object(Bin) -> Bin.
parse_json_array(Bin) -> Bin.

%% Initialize the JavaScript trading engine
init_trading_engine(JsPid) ->
    TradingEngine = trading_engine_js(),
    case mquickjs:eval(JsPid, TradingEngine) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% The JavaScript trading engine code
trading_engine_js() ->
    <<"
// ============================================================
// Stock Exchange Trading Engine
// All state is maintained in JavaScript across Erlang calls
// ============================================================

var exchange = (function() {
    // Private state
    var traders = {};           // trader_id -> {cash, holdings, orders}
    var orderBooks = {};        // symbol -> {bids: [], asks: []}
    var prices = {};            // symbol -> current_price
    var trades = [];            // all executed trades
    var nextOrderId = 1;
    var tradeId = 1;

    // Initialize some stocks with starting prices
    var symbols = ['AAPL', 'GOOG', 'MSFT', 'AMZN', 'TSLA'];
    for (var i = 0; i < symbols.length; i++) {
        var sym = symbols[i];
        prices[sym] = 100 + Math.floor(Math.random() * 100);
        orderBooks[sym] = { bids: [], asks: [] };
    }

    // Helper: format money
    function formatMoney(amount) {
        return '$' + amount.toFixed(2);
    }

    // Register a new trader with initial stock holdings
    function registerTrader(traderId) {
        if (traders[traderId]) {
            return 'error:trader_already_exists';
        }

        // Give each trader some random initial holdings
        var initialHoldings = {};
        for (var i = 0; i < symbols.length; i++) {
            // Each trader starts with 5-15 shares of each stock
            initialHoldings[symbols[i]] = 5 + Math.floor(Math.random() * 11);
        }

        traders[traderId] = {
            cash: 0,
            holdings: initialHoldings,
            orders: [],
            tradeHistory: []
        };
        return JSON.stringify({status: 'ok', trader: traderId, initialHoldings: initialHoldings});
    }

    // Get trader's portfolio
    function getPortfolio(traderId) {
        var trader = traders[traderId];
        if (!trader) {
            return 'error:trader_not_found';
        }

        var totalValue = trader.cash;
        var holdingsValue = {};

        for (var sym in trader.holdings) {
            var qty = trader.holdings[sym];
            var price = prices[sym] || 0;
            var value = qty * price;
            holdingsValue[sym] = {quantity: qty, price: price, value: value};
            totalValue += value;
        }

        return JSON.stringify({
            trader: traderId,
            cash: trader.cash,
            holdings: holdingsValue,
            openOrders: trader.orders.length,
            totalValue: totalValue
        });
    }

    // Deposit cash
    function deposit(traderId, amount) {
        var trader = traders[traderId];
        if (!trader) return 'error:trader_not_found';
        if (amount <= 0) return 'error:invalid_amount';

        trader.cash += amount;
        return JSON.stringify({status: 'ok', cash: trader.cash});
    }

    // Withdraw cash
    function withdraw(traderId, amount) {
        var trader = traders[traderId];
        if (!trader) return 'error:trader_not_found';
        if (amount <= 0) return 'error:invalid_amount';
        if (trader.cash < amount) return 'error:insufficient_funds';

        trader.cash -= amount;
        return JSON.stringify({status: 'ok', cash: trader.cash});
    }

    // Match orders in the order book
    function matchOrders(symbol) {
        var book = orderBooks[symbol];
        if (!book) return;

        // Sort bids descending (highest first), asks ascending (lowest first)
        book.bids.sort(function(a, b) { return b.price - a.price; });
        book.asks.sort(function(a, b) { return a.price - b.price; });

        while (book.bids.length > 0 && book.asks.length > 0) {
            var bid = book.bids[0];
            var ask = book.asks[0];

            // Check if orders can match
            if (bid.price < ask.price) break;

            // Execute trade at the ask price (price-time priority)
            var tradeQty = Math.min(bid.quantity, ask.quantity);
            var tradePrice = ask.price;

            // Record the trade
            var trade = {
                id: tradeId++,
                symbol: symbol,
                price: tradePrice,
                quantity: tradeQty,
                buyer: bid.traderId,
                seller: ask.traderId,
                timestamp: Date.now()
            };
            trades.push(trade);

            // Update portfolios
            var buyer = traders[bid.traderId];
            var seller = traders[ask.traderId];

            var cost = tradeQty * tradePrice;

            // Buyer pays and receives shares
            buyer.cash -= cost;
            buyer.holdings[symbol] = (buyer.holdings[symbol] || 0) + tradeQty;
            buyer.tradeHistory.push(trade);

            // Seller receives cash and loses shares
            seller.cash += cost;
            seller.holdings[symbol] = (seller.holdings[symbol] || 0) - tradeQty;
            if (seller.holdings[symbol] === 0) delete seller.holdings[symbol];
            seller.tradeHistory.push(trade);

            // Update order quantities
            bid.quantity -= tradeQty;
            ask.quantity -= tradeQty;

            // Remove filled orders
            if (bid.quantity === 0) {
                book.bids.shift();
                removeOrderFromTrader(bid.traderId, bid.orderId);
            }
            if (ask.quantity === 0) {
                book.asks.shift();
                removeOrderFromTrader(ask.traderId, ask.orderId);
            }

            // Update last trade price
            prices[symbol] = tradePrice;

            print('TRADE: ' + trade.buyer + ' bought ' + tradeQty + ' ' + symbol +
                  ' from ' + trade.seller + ' @ $' + tradePrice.toFixed(2));
        }
    }

    // Remove order from trader's order list
    function removeOrderFromTrader(traderId, orderId) {
        var trader = traders[traderId];
        if (!trader) return;
        trader.orders = trader.orders.filter(function(o) { return o.orderId !== orderId; });
    }

    // Place an order (buy or sell)
    function placeOrder(traderId, symbol, side, quantity) {
        var trader = traders[traderId];
        if (!trader) return 'error:trader_not_found';
        if (!prices[symbol]) return 'error:unknown_symbol';
        if (quantity <= 0) return 'error:invalid_quantity';

        var currentPrice = prices[symbol];

        // Use aggressive pricing - randomize around current price
        // This ensures orders will cross and trades will execute
        var randomFactor = 0.98 + Math.random() * 0.04;  // 98% to 102%
        var price;
        if (side === 'buy') {
            price = currentPrice * (1 + Math.random() * 0.02);  // Up to 2% above
            var cost = price * quantity;
            if (trader.cash < cost) {
                return 'error:insufficient_funds:need_' + cost.toFixed(2) + '_have_' + trader.cash.toFixed(2);
            }
        } else {
            price = currentPrice * (1 - Math.random() * 0.02);  // Up to 2% below
            var holding = trader.holdings[symbol] || 0;
            if (holding < quantity) {
                return 'error:insufficient_shares:need_' + quantity + '_have_' + holding;
            }
        }

        var order = {
            orderId: nextOrderId++,
            traderId: traderId,
            symbol: symbol,
            side: side,
            price: Math.round(price * 100) / 100,
            quantity: quantity,
            timestamp: Date.now()
        };

        // Add to order book
        var book = orderBooks[symbol];
        if (side === 'buy') {
            book.bids.push(order);
        } else {
            book.asks.push(order);
        }

        // Track order for trader
        trader.orders.push(order);

        print('ORDER: ' + traderId + ' ' + side + ' ' + quantity + ' ' + symbol + ' @ $' + order.price.toFixed(2));

        // Try to match orders
        matchOrders(symbol);

        return JSON.stringify({
            status: 'ok',
            orderId: order.orderId,
            symbol: symbol,
            side: side,
            price: order.price,
            quantity: quantity
        });
    }

    // Cancel an order
    function cancelOrder(traderId, orderId) {
        var trader = traders[traderId];
        if (!trader) return 'error:trader_not_found';

        var order = null;
        for (var i = 0; i < trader.orders.length; i++) {
            if (trader.orders[i].orderId === orderId) {
                order = trader.orders[i];
                break;
            }
        }

        if (!order) return 'error:order_not_found';

        // Remove from order book
        var book = orderBooks[order.symbol];
        var list = order.side === 'buy' ? book.bids : book.asks;
        for (var i = 0; i < list.length; i++) {
            if (list[i].orderId === orderId) {
                list.splice(i, 1);
                break;
            }
        }

        // Remove from trader
        removeOrderFromTrader(traderId, orderId);

        return JSON.stringify({status: 'ok', cancelled: orderId});
    }

    // Get order book for a symbol
    function getOrderBook(symbol) {
        var book = orderBooks[symbol];
        if (!book) return 'error:unknown_symbol';

        return JSON.stringify({
            symbol: symbol,
            price: prices[symbol],
            bids: book.bids.slice(0, 5),  // Top 5 bids
            asks: book.asks.slice(0, 5)   // Top 5 asks
        });
    }

    // Get current price
    function getPrice(symbol) {
        var price = prices[symbol];
        if (price === undefined) return 'error:unknown_symbol';
        return JSON.stringify({symbol: symbol, price: price});
    }

    // Get all prices
    function getAllPrices() {
        return JSON.stringify(prices);
    }

    // Get market statistics
    function getMarketStats() {
        var stats = {
            totalTrades: trades.length,
            traderCount: Object.keys(traders).length,
            symbols: Object.keys(prices).length,
            recentTrades: trades.slice(-10)
        };
        return JSON.stringify(stats);
    }

    // Get trade history for a trader
    function getTradeHistory(traderId) {
        var trader = traders[traderId];
        if (!trader) return 'error:trader_not_found';
        return JSON.stringify(trader.tradeHistory.slice(-20));
    }

    // Public API
    return {
        registerTrader: registerTrader,
        getPortfolio: getPortfolio,
        deposit: deposit,
        withdraw: withdraw,
        placeOrder: placeOrder,
        cancelOrder: cancelOrder,
        getOrderBook: getOrderBook,
        getPrice: getPrice,
        getAllPrices: getAllPrices,
        getMarketStats: getMarketStats,
        getTradeHistory: getTradeHistory
    };
})();

'Trading engine initialized'
">>.
