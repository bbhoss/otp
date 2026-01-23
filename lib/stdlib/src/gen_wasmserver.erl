%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2024-2025. All Rights Reserved.
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
-module(gen_wasmserver).
-moduledoc """
Generic WASM server behavior.

This behavior module provides a server that executes WebAssembly (WASM)
code for handling requests. It follows the same patterns as `gen_server`
but routes callbacks to exported WASM functions instead of Erlang callbacks.

A `gen_wasmserver` process is initialized with a WASM binary that must
export the following functions according to the WASI Component Model:

```
  wasm-init(args: list<u8>) -> result<list<u8>, string>
  wasm-handle-call(request: list<u8>, from: list<u8>, state: list<u8>) -> result<call-result, string>
  wasm-handle-cast(request: list<u8>, state: list<u8>) -> result<cast-result, string>
  wasm-handle-info(info: list<u8>, state: list<u8>) -> result<cast-result, string>
  wasm-terminate(reason: list<u8>, state: list<u8>) -> result<unit, string>
```

The Erlang terms are encoded using the External Term Format (ETF) before
being passed to the WASM functions, and decoded from ETF when returned.

## Example

```erlang
%% Load and start a WASM server
{ok, WasmBinary} = file:read_file("my_server.wasm"),
{ok, Pid} = gen_wasmserver:start_link(WasmBinary, InitArgs, []).

%% Make calls to the WASM server
Reply = gen_wasmserver:call(Pid, {get_value, key}).

%% Cast messages
ok = gen_wasmserver:cast(Pid, {set_value, key, value}).
```

## See Also

`m:gen_server`, `m:gen_statem`
""".

%%% ---------------------------------------------------
%%%
%%% The idea behind THIS server is that a WASM binary
%%% provides callback functions to handle different
%%% kinds of inputs. The WASM binary must export specific
%%% functions that match the gen_server callback pattern.
%%%
%%% The WASM module should export:
%%%
%%%   wasm_init(Args :: binary()) -> {ok, State} | {error, Reason}
%%%     ==> {ok, State :: binary()}
%%%         {stop, Reason :: binary()}
%%%         ignore
%%%
%%%   wasm_handle_call(Msg :: binary(), From :: binary(), State :: binary())
%%%     ==> {reply, Reply, State}
%%%         {noreply, State}
%%%         {stop, Reason, Reply, State}
%%%
%%%   wasm_handle_cast(Msg :: binary(), State :: binary())
%%%     ==> {noreply, State}
%%%         {stop, Reason, State}
%%%
%%%   wasm_handle_info(Info :: binary(), State :: binary())
%%%     ==> {noreply, State}
%%%         {stop, Reason, State}
%%%
%%%   wasm_terminate(Reason :: binary(), State :: binary())
%%%     ==> ok
%%%
%%% All arguments and return values are encoded using ETF (External Term Format)
%%%
%%% ---------------------------------------------------

%% API
-export([start/3, start/4,
         start_link/3, start_link/4,
         start_monitor/3, start_monitor/4,
         stop/1, stop/3,
         call/2, call/3,
         cast/2, reply/2]).

%% System exports
-export([system_continue/3,
         system_terminate/4,
         system_code_change/4,
         system_get_state/1,
         system_replace_state/2,
         format_status/2]).

-behaviour(sys).

%% logger callback
-export([format_log/1, format_log/2]).

%% Internal exports
-export([init_it/6]).

-include("logger.hrl").

-export_type(
   [from/0,
    wasm_binary/0,
    wasm_state/0]).

-export_type(
   [server_name/0,
    server_ref/0,
    start_opt/0,
    start_ret/0,
    start_mon_ret/0]).

-define(
   STACKTRACE(),
   element(2, erlang:process_info(self(), current_stacktrace))).

-define(
    is_timeout(X),
    ( (X) =:= infinity orelse ( is_integer(X) andalso (X) >= 0 ) )
).

%% The WASM instance handle - opaque reference to the loaded WASM module
-record(wasm_instance, {
    ref :: reference(),           %% NIF resource reference
    exports :: #{atom() => arity()} %% Exported functions
}).

%% Server data record - similar to gen_server but for WASM
-record(wasm_server_data, {
    parent :: pid(),
    tag = make_ref() :: reference(),
    name :: term(),
    wasm_instance :: #wasm_instance{},
    hibernate_after :: timeout()
}).

%%%=========================================================================
%%%  Type Definitions
%%%=========================================================================

-doc "Binary containing compiled WASM code (WebAssembly binary format).".
-type wasm_binary() :: binary().

-doc "Opaque state managed by the WASM module, encoded as ETF binary.".
-type wasm_state() :: binary().

-doc """
A call's reply destination.

Destination, given to the WASM server for handle_call,
to be used when replying through `reply/2`.
""".
-type from() :: {Client :: pid(), Tag :: gen:reply_tag()}.

-doc """
Server name specification: `local`, `global`, or `via` registered.
""".
-type server_name() ::
        {'local', LocalName :: atom()}
      | {'global', GlobalName :: term()}
      | {'via', RegMod :: module(), ViaName :: term()}.

-doc """
Server specification: `t:pid/0` or registered `t:server_name/0`.
""".
-type server_ref() ::
        pid()
      | (LocalName :: atom())
      | {Name :: atom(), Node :: atom()}
      | {'global', GlobalName :: term()}
      | {'via', RegMod :: module(), ViaName :: term()}.

-doc """
Server start options.
""".
-type start_opt() ::
        {'timeout', Timeout :: timeout()}
      | {'spawn_opt', SpawnOptions :: [proc_lib:start_spawn_option()]}
      | {'hibernate_after', HibernateAfterTimeout :: timeout()}
      | {'debug', Dbgs :: [sys:debug_option()]}.

-doc """
Return value from start functions.
""".
-type start_ret() ::
        {'ok', Pid :: pid()}
      | 'ignore'
      | {'error', Reason :: term()}.

-doc """
Return value from start_monitor functions.
""".
-type start_mon_ret() ::
        {'ok', {Pid :: pid(), MonRef :: reference()}}
      | 'ignore'
      | {'error', Reason :: term()}.

%%%=========================================================================
%%%  API
%%%=========================================================================

-doc """
Start a WASM server, neither linked nor registered.

Starts a standalone `gen_wasmserver` process with the given WASM binary.

`WasmBinary` is the compiled WebAssembly module that must export the
required callback functions.

`Args` are passed to the WASM module's `wasm_init` function after ETF encoding.
""".
-spec start(
        WasmBinary :: wasm_binary(),
        Args :: term(),
        Options :: [start_opt()]
       ) -> start_ret().
start(WasmBinary, Args, Options)
  when is_binary(WasmBinary), is_list(Options) ->
    gen:start(?MODULE, nolink, ?MODULE, {WasmBinary, Args}, Options);
start(WasmBinary, Args, Options) ->
    error(badarg, [WasmBinary, Args, Options]).

-doc """
Start a WASM server, registered but not linked.
""".
-spec start(
        ServerName :: server_name(),
        WasmBinary :: wasm_binary(),
        Args :: term(),
        Options :: [start_opt()]
       ) -> start_ret().
start(ServerName, WasmBinary, Args, Options)
  when is_tuple(ServerName), is_binary(WasmBinary), is_list(Options) ->
    gen:start(?MODULE, nolink, ServerName, ?MODULE, {WasmBinary, Args}, Options);
start(ServerName, WasmBinary, Args, Options) ->
    error(badarg, [ServerName, WasmBinary, Args, Options]).

-doc """
Start a WASM server, linked but not registered.

Creates a `gen_wasmserver` process as part of a supervision tree.
""".
-spec start_link(
        WasmBinary :: wasm_binary(),
        Args :: term(),
        Options :: [start_opt()]
       ) -> start_ret().
start_link(WasmBinary, Args, Options)
  when is_binary(WasmBinary), is_list(Options) ->
    gen:start(?MODULE, link, ?MODULE, {WasmBinary, Args}, Options);
start_link(WasmBinary, Args, Options) ->
    error(badarg, [WasmBinary, Args, Options]).

-doc """
Start a WASM server, linked and registered.
""".
-spec start_link(
        ServerName :: server_name(),
        WasmBinary :: wasm_binary(),
        Args :: term(),
        Options :: [start_opt()]
       ) -> start_ret().
start_link(ServerName, WasmBinary, Args, Options)
  when is_tuple(ServerName), is_binary(WasmBinary), is_list(Options) ->
    gen:start(?MODULE, link, ServerName, ?MODULE, {WasmBinary, Args}, Options);
start_link(ServerName, WasmBinary, Args, Options) ->
    error(badarg, [ServerName, WasmBinary, Args, Options]).

-doc """
Start a WASM server, monitored but not linked or registered.
""".
-spec start_monitor(
        WasmBinary :: wasm_binary(),
        Args :: term(),
        Options :: [start_opt()]
       ) -> start_mon_ret().
start_monitor(WasmBinary, Args, Options)
  when is_binary(WasmBinary), is_list(Options) ->
    gen:start(?MODULE, monitor, ?MODULE, {WasmBinary, Args}, Options);
start_monitor(WasmBinary, Args, Options) ->
    error(badarg, [WasmBinary, Args, Options]).

-doc """
Start a WASM server, monitored and registered.
""".
-spec start_monitor(
        ServerName :: server_name(),
        WasmBinary :: wasm_binary(),
        Args :: term(),
        Options :: [start_opt()]
       ) -> start_mon_ret().
start_monitor(ServerName, WasmBinary, Args, Options)
  when is_tuple(ServerName), is_binary(WasmBinary), is_list(Options) ->
    gen:start(?MODULE, monitor, ServerName, ?MODULE, {WasmBinary, Args}, Options);
start_monitor(ServerName, WasmBinary, Args, Options) ->
    error(badarg, [ServerName, WasmBinary, Args, Options]).

-doc """
Stop a WASM server.

Orders the `gen_wasmserver` specified by `ServerRef` to exit with
the specified `Reason` and waits for it to terminate.
""".
-spec stop(ServerRef :: server_ref()) -> ok.
stop(ServerRef) ->
    gen:stop(ServerRef).

-spec stop(
        ServerRef :: server_ref(),
        Reason :: term(),
        Timeout :: timeout()
       ) -> ok.
stop(ServerRef, Reason, Timeout) ->
    gen:stop(ServerRef, Reason, Timeout).

-doc """
Call a WASM server.

Makes a synchronous call to the `gen_wasmserver` process and waits
for its reply. The request is encoded to ETF and passed to the WASM
module's `wasm_handle_call` function.
""".
-spec call(ServerRef :: server_ref(), Request :: term()) -> Reply :: term().
call(ServerRef, Request) ->
    case catch gen:call(ServerRef, '$gen_call', Request) of
        {ok, Res} ->
            Res;
        {'EXIT', Reason} ->
            exit({Reason, {?MODULE, call, [ServerRef, Request]}})
    end.

-spec call(
        ServerRef :: server_ref(),
        Request :: term(),
        Timeout :: timeout()
       ) -> Reply :: term().
call(ServerRef, Request, Timeout)
  when ?is_timeout(Timeout) ->
    case catch gen:call(ServerRef, '$gen_call', Request, Timeout) of
        {ok, Res} ->
            Res;
        {'EXIT', Reason} ->
            exit({Reason, {?MODULE, call, [ServerRef, Request, Timeout]}})
    end;
call(ServerRef, Request, Timeout) ->
    error(badarg, [ServerRef, Request, Timeout]).

-doc """
Cast a request to a WASM server.

Sends an asynchronous request to the `gen_wasmserver` and returns
`ok` immediately, ignoring if the destination does not exist.
""".
-spec cast(ServerRef :: server_ref(), Request :: term()) -> ok.
cast({global,Name}, Request) ->
    catch global:send(Name, cast_msg(Request)),
    ok;
cast({via, Mod, Name}, Request) ->
    catch Mod:send(Name, cast_msg(Request)),
    ok;
cast({Name,Node}=Dest, Request) when is_atom(Name), is_atom(Node) ->
    do_cast(Dest, Request);
cast(Dest, Request) when is_atom(Dest) ->
    do_cast(Dest, Request);
cast(Dest, Request) when is_pid(Dest) ->
    do_cast(Dest, Request).

do_cast(Dest, Request) ->
    do_send(Dest, cast_msg(Request)),
    ok.

cast_msg(Request) -> {'$gen_cast', Request}.

-doc """
Send a reply to a client.

This function can be used by the WASM callback handler to explicitly
send a reply to a client when the reply cannot be passed in the
return value of wasm_handle_call.
""".
-spec reply(Client :: from(), Reply :: term()) -> ok.
reply(Client, Reply) ->
    gen:reply(Client, Reply).

%%%========================================================================
%%% Gen-callback functions
%%%========================================================================

%%% ---------------------------------------------------
%%% Initiate the new process.
%%% Load the WASM binary and call wasm_init.
%%% ---------------------------------------------------
-doc false.
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name0, _Mod, {WasmBinary, Args}, Options) ->
    Name = gen:name(Name0),
    Debug = gen:debug_options(Name, Options),
    HibernateAfter = gen:hibernate_after(Options),
    case load_wasm_module(WasmBinary) of
        {ok, WasmInstance} ->
            ServerData = #wasm_server_data{
                parent = Parent,
                name = Name,
                wasm_instance = WasmInstance,
                hibernate_after = HibernateAfter
            },
            case wasm_init(WasmInstance, Args) of
                {ok, State} ->
                    proc_lib:init_ack(Starter, {ok, self()}),
                    loop(ServerData, State, infinity, Debug);
                {ok, State, Timeout} when ?is_timeout(Timeout) ->
                    proc_lib:init_ack(Starter, {ok, self()}),
                    loop(ServerData, State, Timeout, Debug);
                {ok, State, hibernate} ->
                    proc_lib:init_ack(Starter, {ok, self()}),
                    loop(ServerData, State, hibernate, Debug);
                {stop, Reason} ->
                    gen:unregister_name(Name0),
                    unload_wasm_module(WasmInstance),
                    exit(Reason);
                {error, Reason} ->
                    gen:unregister_name(Name0),
                    unload_wasm_module(WasmInstance),
                    proc_lib:init_fail(Starter, {error, Reason}, {exit, normal});
                ignore ->
                    gen:unregister_name(Name0),
                    unload_wasm_module(WasmInstance),
                    proc_lib:init_fail(Starter, ignore, {exit, normal});
                Else ->
                    gen:unregister_name(Name0),
                    unload_wasm_module(WasmInstance),
                    exit({bad_return_value, Else})
            end;
        {error, Reason} ->
            gen:unregister_name(Name0),
            proc_lib:init_fail(Starter, {error, {wasm_load_failed, Reason}}, {exit, normal})
    end.

%%%========================================================================
%%% Internal functions
%%%========================================================================

%%% ---------------------------------------------------
%%% The MAIN loop.
%%% ---------------------------------------------------

loop(ServerData, State, hibernate, Debug) ->
    receive
        Msg ->
            erlang:garbage_collect(),
            decode_msg(ServerData, State, hibernate, Debug, Msg)
    after 0 ->
        loop_hibernate(ServerData, State, Debug)
    end;
%%
loop(#wasm_server_data{hibernate_after = HibAfter} = ServerData, State, infinity, Debug) ->
    receive
        Msg ->
            decode_msg(ServerData, State, infinity, Debug, Msg)
    after HibAfter ->
        loop_hibernate(ServerData, State, Debug)
    end;
%%
loop(ServerData, State, Time, Debug) when ?is_timeout(Time) ->
    receive
        Msg ->
            decode_msg(ServerData, State, Time, Debug, Msg)
    after Time ->
        decode_msg(ServerData, State, infinity, Debug, timeout)
    end.

loop_hibernate(ServerData, State, Debug) ->
    erlang:hibernate(?MODULE, loop_wakeup, [ServerData, State, Debug]).

-doc false.
loop_wakeup(ServerData, State, Debug) ->
    receive
        Msg ->
            decode_msg(ServerData, State, hibernate, Debug, Msg)
    end.

decode_msg(#wasm_server_data{parent = Parent} = ServerData, State, HibT, Debug, Msg) ->
    case Msg of
        {system, From, Req} ->
            sys:handle_system_msg(Req, From, Parent, ?MODULE, Debug,
                                  [ServerData, State, HibT], HibT =:= hibernate);
        {'EXIT', Parent, Reason} ->
            terminate(ServerData, State, Msg, undefined, Reason, ?STACKTRACE(), Debug);
        _ ->
            handle_msg(ServerData, State, Msg, Debug)
    end.

%%% ---------------------------------------------------
%%% Message handling
%%% ---------------------------------------------------

handle_msg(ServerData, State, {'$gen_call', From, Msg}, Debug) ->
    #wasm_server_data{wasm_instance = WasmInstance, name = Name} = ServerData,
    case wasm_handle_call(WasmInstance, Msg, From, State) of
        {reply, Reply, NState} ->
            reply(From, Reply),
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {out, Reply, From, NState}),
            loop(ServerData, NState, infinity, Debug1);
        {reply, Reply, NState, Timeout} when ?is_timeout(Timeout) ->
            reply(From, Reply),
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {out, Reply, From, NState}),
            loop(ServerData, NState, Timeout, Debug1);
        {reply, Reply, NState, hibernate} ->
            reply(From, Reply),
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {out, Reply, From, NState}),
            loop(ServerData, NState, hibernate, Debug1);
        {noreply, NState} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, infinity, Debug1);
        {noreply, NState, Timeout} when ?is_timeout(Timeout) ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, Timeout, Debug1);
        {noreply, NState, hibernate} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, hibernate, Debug1);
        {stop, Reason, Reply, NState} ->
            try
                terminate(ServerData, NState, Msg, From, Reason, ?STACKTRACE(), Debug)
            after
                reply(From, Reply)
            end;
        {stop, Reason, NState} ->
            terminate(ServerData, NState, Msg, From, Reason, ?STACKTRACE(), Debug);
        {'EXIT', Class, Reason, Stacktrace} ->
            terminate(ServerData, State, Msg, From, Class, Reason, Stacktrace, Debug);
        BadReturn ->
            terminate(ServerData, State, Msg, From, {bad_return_value, BadReturn}, ?STACKTRACE(), Debug)
    end;

handle_msg(ServerData, State, {'$gen_cast', Msg}, Debug) ->
    #wasm_server_data{wasm_instance = WasmInstance, name = Name} = ServerData,
    case wasm_handle_cast(WasmInstance, Msg, State) of
        {noreply, NState} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, infinity, Debug1);
        {noreply, NState, Timeout} when ?is_timeout(Timeout) ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, Timeout, Debug1);
        {noreply, NState, hibernate} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, hibernate, Debug1);
        {stop, Reason, NState} ->
            terminate(ServerData, NState, {'$gen_cast', Msg}, undefined, Reason, ?STACKTRACE(), Debug);
        {'EXIT', Class, Reason, Stacktrace} ->
            terminate(ServerData, State, {'$gen_cast', Msg}, undefined, Class, Reason, Stacktrace, Debug);
        BadReturn ->
            terminate(ServerData, State, {'$gen_cast', Msg}, undefined, {bad_return_value, BadReturn}, ?STACKTRACE(), Debug)
    end;

handle_msg(ServerData, State, Info, Debug) ->
    #wasm_server_data{wasm_instance = WasmInstance, name = Name} = ServerData,
    case wasm_handle_info(WasmInstance, Info, State) of
        {noreply, NState} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, infinity, Debug1);
        {noreply, NState, Timeout} when ?is_timeout(Timeout) ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, Timeout, Debug1);
        {noreply, NState, hibernate} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                     {noreply, NState}),
            loop(ServerData, NState, hibernate, Debug1);
        {stop, Reason, NState} ->
            terminate(ServerData, NState, Info, undefined, Reason, ?STACKTRACE(), Debug);
        {'EXIT', Class, Reason, Stacktrace} ->
            terminate(ServerData, State, Info, undefined, Class, Reason, Stacktrace, Debug);
        BadReturn ->
            terminate(ServerData, State, Info, undefined, {bad_return_value, BadReturn}, ?STACKTRACE(), Debug)
    end.

%%% ---------------------------------------------------
%%% Termination
%%% ---------------------------------------------------

terminate(ServerData, State, Msg, From, Reason, Stacktrace, Debug) ->
    terminate(ServerData, State, Msg, From, exit, Reason, Stacktrace, Debug).

terminate(ServerData, State, Msg, From, Class, Reason, Stacktrace, Debug) ->
    #wasm_server_data{wasm_instance = WasmInstance, name = Name} = ServerData,
    %% Call WASM terminate
    case catch wasm_terminate(WasmInstance, Reason, State) of
        {'EXIT', _, _, _} = ExitTuple ->
            error_info(ExitTuple, Name, Msg, From, State, Debug),
            ok;
        _ ->
            ok
    end,
    %% Unload the WASM module
    unload_wasm_module(WasmInstance),
    %% Handle the exit
    case {Class, Reason} of
        {exit, normal} -> ok;
        {exit, shutdown} -> ok;
        {exit, {shutdown, _}} -> ok;
        _ ->
            error_info({Class, Reason, Stacktrace}, Name, Msg, From, State, Debug)
    end,
    case Class of
        exit -> exit(Reason);
        error -> erlang:raise(Class, Reason, Stacktrace);
        throw -> erlang:raise(Class, Reason, Stacktrace)
    end.

error_info({Class, Reason, Stacktrace}, Name, Msg, From, State, Debug) ->
    ?LOG_ERROR(
       #{label => {gen_wasmserver, terminate},
         name => Name,
         last_message => Msg,
         from => From,
         state => format_state(State),
         log => format_log_state(Debug),
         reason => {Class, Reason, Stacktrace}},
       #{domain => [otp],
         report_cb => fun gen_wasmserver:format_log/2,
         error_logger =>
             #{tag => error,
               report_cb => fun gen_wasmserver:format_log/1}}).

format_state(State) when is_binary(State), byte_size(State) > 100 ->
    <<Prefix:100/binary, _/binary>> = State,
    {truncated, Prefix};
format_state(State) ->
    State.

format_log_state([]) -> [];
format_log_state(_Debug) -> '*'.

%%% ---------------------------------------------------
%%% Send functions
%%% ---------------------------------------------------

do_send(Dest, Msg) ->
    try erlang:send(Dest, Msg)
    catch
        error:_ -> ok
    end,
    ok.

%%% ---------------------------------------------------
%%% System callbacks
%%% ---------------------------------------------------

-doc false.
system_continue(Parent, Debug, [#wasm_server_data{parent = Parent} = ServerData, State, HibT]) ->
    loop(ServerData, State, HibT, Debug).

-doc false.
-spec system_terminate(_, _, _, _) -> no_return().
system_terminate(Reason, _Parent, Debug, [ServerData, State, _HibT]) ->
    terminate(ServerData, State, [], undefined, Reason, ?STACKTRACE(), Debug).

-doc false.
system_code_change([ServerData, State, HibT], _Module, _OldVsn, _Extra) ->
    %% WASM modules don't support code change in the traditional sense
    {ok, [ServerData, State, HibT]}.

-doc false.
system_get_state([_ServerData, State, _HibT]) ->
    {ok, State}.

-doc false.
system_replace_state(StateFun, [ServerData, State, HibT]) ->
    NState = StateFun(State),
    {ok, NState, [ServerData, NState, HibT]}.

%%% ---------------------------------------------------
%%% Debug printing
%%% ---------------------------------------------------

print_event(Dev, {in, Msg}, Name) ->
    case Msg of
        {'$gen_call', {From, _Tag}, Call} ->
            io:format(Dev, "*DBG* ~tp got call ~tp from ~tw~n",
                      [Name, Call, From]);
        {'$gen_cast', Cast} ->
            io:format(Dev, "*DBG* ~tp got cast ~tp~n",
                      [Name, Cast]);
        _ ->
            io:format(Dev, "*DBG* ~tp got ~tp~n", [Name, Msg])
    end;
print_event(Dev, {out, Msg, {To, _Tag}, State}, Name) ->
    io:format(Dev, "*DBG* ~tp sent ~tp to ~tw, new state ~tp~n",
              [Name, Msg, To, State]);
print_event(Dev, {noreply, State}, Name) ->
    io:format(Dev, "*DBG* ~tp new state ~tp~n", [Name, State]);
print_event(Dev, Event, Name) ->
    io:format(Dev, "*DBG* ~tp event ~tp~n", [Name, Event]).

-doc false.
format_status(Opt, StatusData) ->
    [PDict, SysState, Parent, Debug, [ServerData, State, _HibT]] = StatusData,
    #wasm_server_data{name = Name} = ServerData,
    Header = gen:format_status_header("Status for WASM server", Name),
    Log = sys:get_log(Debug),
    Specific =
        case Opt of
            terminate ->
                [{data, [{"State", State}]}];
            _ ->
                [{data, [{"State", State}]}]
        end,
    [{header, Header},
     {data, [{"Status", SysState},
             {"Parent", Parent},
             {"Logged events", Log}]} |
     Specific].

%%% ---------------------------------------------------
%%% Logger formatting
%%% ---------------------------------------------------

-doc false.
format_log(Report) ->
    Depth = error_logger:get_format_depth(),
    FormatOpts = #{chars_limit => unlimited,
                   depth => Depth,
                   single_line => false,
                   encoding => utf8},
    format_log_multi(limit_report(Report, Depth), FormatOpts).

-doc false.
format_log(Report, FormatOpts0) ->
    Default = #{chars_limit => unlimited,
                depth => error_logger:get_format_depth(),
                single_line => false,
                encoding => utf8},
    FormatOpts = maps:merge(Default, FormatOpts0),
    IoOpts =
        case FormatOpts of
            #{chars_limit := unlimited} ->
                [];
            #{chars_limit := Limit} ->
                [{chars_limit, Limit}]
        end,
    {Format, Args} = format_log_single(limit_report(Report, maps:get(depth, FormatOpts)), FormatOpts),
    io_lib:format(Format, Args, IoOpts).

limit_report(Report, unlimited) ->
    Report;
limit_report(#{label := {gen_wasmserver, terminate},
               last_message := Msg,
               state := State,
               log := Log,
               reason := Reason} = Report, Depth) ->
    Report#{last_message => io_lib:limit_term(Msg, Depth),
            state => io_lib:limit_term(State, Depth),
            log => [io_lib:limit_term(L, Depth) || L <- Log],
            reason => io_lib:limit_term(Reason, Depth)};
limit_report(Report, _Depth) ->
    Report.

format_log_single(#{label := {gen_wasmserver, terminate},
                    name := Name,
                    last_message := Msg,
                    state := State,
                    log := Log,
                    reason := Reason}, _FormatOpts) ->
    {"** WASM server ~tp terminating~n"
     "** Last message: ~tp~n"
     "** State: ~tp~n"
     "** Log: ~tp~n"
     "** Reason: ~tp~n",
     [Name, Msg, State, Log, Reason]};
format_log_single(Report, _FormatOpts) ->
    {"Unknown report: ~tp~n", [Report]}.

format_log_multi(#{label := {gen_wasmserver, terminate},
                   name := Name,
                   last_message := Msg,
                   state := State,
                   log := Log,
                   reason := Reason}, _FormatOpts) ->
    {"** WASM server ~tp terminating~n"
     "** Last message: ~tp~n"
     "** State: ~tp~n"
     "** Log: ~tp~n"
     "** Reason: ~tp~n",
     [Name, Msg, State, Log, Reason]};
format_log_multi(Report, _FormatOpts) ->
    {"Unknown report: ~tp~n", [Report]}.

%%%========================================================================
%%% WASM Interface Functions (NIF stubs)
%%%========================================================================
%%% These functions interface with the WASM runtime via NIFs.
%%% The actual implementation will be in a NIF library.

%% @doc Load a WASM binary and create an instance
-spec load_wasm_module(WasmBinary :: binary()) ->
    {ok, #wasm_instance{}} | {error, term()}.
load_wasm_module(WasmBinary) ->
    %% This will be implemented as a NIF that:
    %% 1. Validates the WASM binary
    %% 2. Compiles it using a WASM runtime (e.g., wasmtime, wasmer)
    %% 3. Creates an instance with the required imports
    %% 4. Returns a reference to the instance
    case wasm_runtime_nif:load_module(WasmBinary) of
        {ok, Ref, Exports} ->
            {ok, #wasm_instance{ref = Ref, exports = Exports}};
        {error, _} = Error ->
            Error
    end.

%% @doc Unload a WASM module and free resources
-spec unload_wasm_module(#wasm_instance{}) -> ok.
unload_wasm_module(#wasm_instance{ref = Ref}) ->
    wasm_runtime_nif:unload_module(Ref).

%% @doc Call wasm_init in the WASM module
-spec wasm_init(#wasm_instance{}, term()) ->
    {ok, wasm_state()} |
    {ok, wasm_state(), timeout() | hibernate} |
    {stop, term()} |
    {error, term()} |
    ignore.
wasm_init(#wasm_instance{ref = Ref, exports = Exports}, Args) ->
    case maps:is_key(wasm_init, Exports) of
        true ->
            EncodedArgs = term_to_binary(Args),
            case wasm_runtime_nif:call_function(Ref, wasm_init, [EncodedArgs]) of
                {ok, EncodedResult} ->
                    decode_init_result(EncodedResult);
                {error, Reason} ->
                    {'EXIT', error, {wasm_call_failed, Reason}, []}
            end;
        false ->
            {error, {wasm_export_missing, wasm_init}}
    end.

decode_init_result(EncodedResult) ->
    try binary_to_term(EncodedResult) of
        {ok, State} -> {ok, State};
        {ok, State, Action} -> {ok, State, Action};
        {stop, Reason} -> {stop, Reason};
        {error, Reason} -> {error, Reason};
        ignore -> ignore;
        Other -> {error, {bad_init_return, Other}}
    catch
        _:_ -> {error, {decode_failed, EncodedResult}}
    end.

%% @doc Call wasm_handle_call in the WASM module
-spec wasm_handle_call(#wasm_instance{}, term(), from(), wasm_state()) ->
    {reply, term(), wasm_state()} |
    {reply, term(), wasm_state(), timeout() | hibernate} |
    {noreply, wasm_state()} |
    {noreply, wasm_state(), timeout() | hibernate} |
    {stop, term(), term(), wasm_state()} |
    {stop, term(), wasm_state()} |
    {'EXIT', atom(), term(), list()}.
wasm_handle_call(#wasm_instance{ref = Ref, exports = Exports}, Request, From, State) ->
    case maps:is_key(wasm_handle_call, Exports) of
        true ->
            EncodedRequest = term_to_binary(Request),
            EncodedFrom = term_to_binary(From),
            EncodedState = ensure_binary_state(State),
            case wasm_runtime_nif:call_function(Ref, wasm_handle_call,
                                                [EncodedRequest, EncodedFrom, EncodedState]) of
                {ok, EncodedResult} ->
                    decode_call_result(EncodedResult);
                {error, Reason} ->
                    {'EXIT', error, {wasm_call_failed, Reason}, []}
            end;
        false ->
            %% Default: return error for unhandled calls
            {reply, {error, no_handle_call}, State}
    end.

decode_call_result(EncodedResult) ->
    try binary_to_term(EncodedResult) of
        {reply, Reply, NewState} -> {reply, Reply, NewState};
        {reply, Reply, NewState, Action} -> {reply, Reply, NewState, Action};
        {noreply, NewState} -> {noreply, NewState};
        {noreply, NewState, Action} -> {noreply, NewState, Action};
        {stop, Reason, Reply, NewState} -> {stop, Reason, Reply, NewState};
        {stop, Reason, NewState} -> {stop, Reason, NewState};
        Other -> {bad_return_value, Other}
    catch
        _:_ -> {'EXIT', error, {decode_failed, EncodedResult}, []}
    end.

%% @doc Call wasm_handle_cast in the WASM module
-spec wasm_handle_cast(#wasm_instance{}, term(), wasm_state()) ->
    {noreply, wasm_state()} |
    {noreply, wasm_state(), timeout() | hibernate} |
    {stop, term(), wasm_state()} |
    {'EXIT', atom(), term(), list()}.
wasm_handle_cast(#wasm_instance{ref = Ref, exports = Exports}, Request, State) ->
    case maps:is_key(wasm_handle_cast, Exports) of
        true ->
            EncodedRequest = term_to_binary(Request),
            EncodedState = ensure_binary_state(State),
            case wasm_runtime_nif:call_function(Ref, wasm_handle_cast,
                                                [EncodedRequest, EncodedState]) of
                {ok, EncodedResult} ->
                    decode_cast_result(EncodedResult);
                {error, Reason} ->
                    {'EXIT', error, {wasm_call_failed, Reason}, []}
            end;
        false ->
            %% Default: ignore unhandled casts
            {noreply, State}
    end.

decode_cast_result(EncodedResult) ->
    try binary_to_term(EncodedResult) of
        {noreply, NewState} -> {noreply, NewState};
        {noreply, NewState, Action} -> {noreply, NewState, Action};
        {stop, Reason, NewState} -> {stop, Reason, NewState};
        Other -> {bad_return_value, Other}
    catch
        _:_ -> {'EXIT', error, {decode_failed, EncodedResult}, []}
    end.

%% @doc Call wasm_handle_info in the WASM module
-spec wasm_handle_info(#wasm_instance{}, term(), wasm_state()) ->
    {noreply, wasm_state()} |
    {noreply, wasm_state(), timeout() | hibernate} |
    {stop, term(), wasm_state()} |
    {'EXIT', atom(), term(), list()}.
wasm_handle_info(#wasm_instance{ref = Ref, exports = Exports}, Info, State) ->
    case maps:is_key(wasm_handle_info, Exports) of
        true ->
            EncodedInfo = term_to_binary(Info),
            EncodedState = ensure_binary_state(State),
            case wasm_runtime_nif:call_function(Ref, wasm_handle_info,
                                                [EncodedInfo, EncodedState]) of
                {ok, EncodedResult} ->
                    decode_cast_result(EncodedResult); %% Same format as cast
                {error, Reason} ->
                    {'EXIT', error, {wasm_call_failed, Reason}, []}
            end;
        false ->
            %% Default: ignore unhandled info messages
            {noreply, State}
    end.

%% @doc Call wasm_terminate in the WASM module
-spec wasm_terminate(#wasm_instance{}, term(), wasm_state()) -> ok | {'EXIT', atom(), term(), list()}.
wasm_terminate(#wasm_instance{ref = Ref, exports = Exports}, Reason, State) ->
    case maps:is_key(wasm_terminate, Exports) of
        true ->
            EncodedReason = term_to_binary(Reason),
            EncodedState = ensure_binary_state(State),
            case wasm_runtime_nif:call_function(Ref, wasm_terminate,
                                                [EncodedReason, EncodedState]) of
                {ok, _} -> ok;
                {error, Reason2} ->
                    {'EXIT', error, {wasm_terminate_failed, Reason2}, []}
            end;
        false ->
            ok
    end.

%% Helper to ensure state is binary for WASM
ensure_binary_state(State) when is_binary(State) -> State;
ensure_binary_state(State) -> term_to_binary(State).
