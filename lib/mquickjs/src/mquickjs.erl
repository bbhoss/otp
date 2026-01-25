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
%% @doc MQuickJS - Erlang interface to the MQuickJS JavaScript engine.
%%
%% This module provides an interface to evaluate JavaScript code using
%% the MQuickJS (Micro QuickJS) JavaScript engine via a C node.
%%
%% == Example Usage ==
%% ```
%% %% Start the JavaScript engine
%% {ok, Pid} = mquickjs:start_link().
%%
%% %% Evaluate JavaScript code
%% {ok, 42} = mquickjs:eval(Pid, "21 + 21").
%% {ok, <<"hello">>} = mquickjs:eval(Pid, "'hello'").
%%
%% %% Execute code with console output
%% {ok, undefined} = mquickjs:eval(Pid, "console.log('Hello, World!')").
%% {ok, <<"Hello, World!\n">>} = mquickjs:get_output(Pid).
%%
%% %% Stop the engine
%% ok = mquickjs:stop(Pid).
%% '''
-module(mquickjs).

-behaviour(gen_server).

%% API exports
-export([start_link/0, start_link/1]).
-export([eval/2, eval/3]).
-export([get_output/1]).
-export([gc/1]).
-export([reset/1, reset/2]).
-export([stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_MEM_SIZE, 256). %% KB

-record(state, {
    cnode_pid :: pid() | undefined,
    cnode_name :: atom(),
    port :: port() | undefined
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the MQuickJS server with default options.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link([]).

%% @doc Start the MQuickJS server with options.
%%
%% Options:
%% <ul>
%%   <li>`{mem_size, integer()}' - Memory size for JS context in KB (default: 256)</li>
%%   <li>`{name, atom()}' - Register the server with this name</li>
%% </ul>
-spec start_link(proplists:proplist()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    case proplists:get_value(name, Opts) of
        undefined ->
            gen_server:start_link(?MODULE, Opts, []);
        Name ->
            gen_server:start_link({local, Name}, ?MODULE, Opts, [])
    end.

%% @doc Evaluate JavaScript code and return the result.
%%
%% The result is converted from JavaScript to Erlang types:
%% <ul>
%%   <li>JS number (integer) -> Erlang integer</li>
%%   <li>JS number (float) -> Erlang float</li>
%%   <li>JS string -> Erlang binary</li>
%%   <li>JS boolean -> Erlang atom (true/false)</li>
%%   <li>JS null -> Erlang atom (null)</li>
%%   <li>JS undefined -> Erlang atom (undefined)</li>
%%   <li>JS object/array -> Erlang binary (string representation)</li>
%% </ul>
-spec eval(pid() | atom(), iodata()) -> {ok, term()} | {error, term()}.
eval(Server, Code) ->
    eval(Server, Code, ?DEFAULT_TIMEOUT).

%% @doc Evaluate JavaScript code with a custom timeout.
-spec eval(pid() | atom(), iodata(), timeout()) -> {ok, term()} | {error, term()}.
eval(Server, Code, Timeout) ->
    gen_server:call(Server, {eval, iolist_to_binary(Code)}, Timeout).

%% @doc Get the console output from the last evaluation.
%%
%% Returns any output that was written using `console.log()' or `print()'.
-spec get_output(pid() | atom()) -> {ok, binary()} | {error, term()}.
get_output(Server) ->
    gen_server:call(Server, get_output, ?DEFAULT_TIMEOUT).

%% @doc Trigger garbage collection in the JavaScript engine.
-spec gc(pid() | atom()) -> ok | {error, term()}.
gc(Server) ->
    gen_server:call(Server, gc, ?DEFAULT_TIMEOUT).

%% @doc Reset the JavaScript context with default memory size.
-spec reset(pid() | atom()) -> ok | {error, term()}.
reset(Server) ->
    reset(Server, ?DEFAULT_MEM_SIZE).

%% @doc Reset the JavaScript context with a specific memory size (in KB).
-spec reset(pid() | atom(), pos_integer()) -> ok | {error, term()}.
reset(Server, MemSizeKB) ->
    gen_server:call(Server, {reset, MemSizeKB}, ?DEFAULT_TIMEOUT).

%% @doc Stop the MQuickJS server.
-spec stop(pid() | atom()) -> ok.
stop(Server) ->
    gen_server:stop(Server).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    MemSize = proplists:get_value(mem_size, Opts, ?DEFAULT_MEM_SIZE),

    %% Generate unique C node name
    Unique = erlang:unique_integer([positive]),
    CNodeName = list_to_atom("mquickjs_" ++ integer_to_list(Unique)),

    case start_cnode(CNodeName, MemSize) of
        {ok, Port} ->
            %% Wait for C node to connect
            case wait_for_cnode(CNodeName, 5000) of
                ok ->
                    {ok, #state{cnode_name = CNodeName, port = Port}};
                {error, Reason} ->
                    port_close(Port),
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({eval, Code}, _From, State) ->
    Reply = send_command(State#state.cnode_name, {eval, Code}),
    {reply, Reply, State};

handle_call(get_output, _From, State) ->
    Reply = send_command(State#state.cnode_name, {get_output}),
    {reply, Reply, State};

handle_call(gc, _From, State) ->
    Reply = send_command(State#state.cnode_name, {gc}),
    {reply, Reply, State};

handle_call({reset, MemSizeKB}, _From, State) ->
    Reply = send_command(State#state.cnode_name, {reset, {MemSizeKB}}),
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Port, Reason}, #state{port = Port} = State) ->
    {stop, {port_terminated, Reason}, State#state{port = undefined}};

handle_info({nodedown, Node}, State) ->
    CNodeName = State#state.cnode_name,
    case atom_to_list(Node) of
        [$c, $_ | Rest] ->
            case list_to_atom(Rest) of
                CNodeName ->
                    {stop, cnode_down, State};
                _ ->
                    {noreply, State}
            end;
        _ ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% Try to gracefully stop the C node
    catch send_command(State#state.cnode_name, {stop}),

    %% Close the port if still open
    case State#state.port of
        undefined -> ok;
        Port -> catch port_close(Port)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
%% Find the C node executable
find_cnode_executable() ->
    %% Try multiple locations
    Candidates = [
        %% In the priv directory of this application
        filename:join([code:priv_dir(mquickjs), "mquickjs_cnode"]),
        %% In the build directory
        filename:join([code:lib_dir(mquickjs), "priv", "mquickjs_cnode"]),
        %% Relative to current directory
        "priv/mquickjs_cnode",
        %% In PATH
        os:find_executable("mquickjs_cnode")
    ],
    find_existing(Candidates).

find_existing([false | Rest]) ->
    find_existing(Rest);
find_existing([Path | Rest]) ->
    case filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> find_existing(Rest)
    end;
find_existing([]) ->
    {error, cnode_not_found}.

%% @private
%% Start the C node process
start_cnode(CNodeName, MemSize) ->
    case find_cnode_executable() of
        {ok, Executable} ->
            Cookie = atom_to_list(erlang:get_cookie()),
            ErlangNode = atom_to_list(node()),

            Args = [
                "-n", atom_to_list(CNodeName),
                "-c", Cookie,
                "-e", ErlangNode,
                "-m", integer_to_list(MemSize)
            ],

            %% Open port to manage the C node process
            Port = open_port({spawn_executable, Executable}, [
                {args, Args},
                exit_status,
                stderr_to_stdout,
                binary
            ]),
            {ok, Port};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% Wait for the C node to connect
wait_for_cnode(CNodeName, Timeout) ->
    FullName = list_to_atom("c_" ++ atom_to_list(CNodeName) ++ "@" ++ get_hostname()),
    wait_for_cnode_loop(FullName, Timeout, erlang:monotonic_time(millisecond)).

wait_for_cnode_loop(FullName, Timeout, StartTime) ->
    Now = erlang:monotonic_time(millisecond),
    Elapsed = Now - StartTime,

    if
        Elapsed >= Timeout ->
            {error, timeout};
        true ->
            case net_adm:ping(FullName) of
                pong ->
                    erlang:monitor_node(FullName, true),
                    ok;
                pang ->
                    timer:sleep(100),
                    wait_for_cnode_loop(FullName, Timeout, StartTime)
            end
    end.

%% @private
%% Get hostname for node name construction
get_hostname() ->
    case node() of
        nonode@nohost ->
            {ok, Hostname} = inet:gethostname(),
            Hostname;
        Node ->
            NodeStr = atom_to_list(Node),
            case string:split(NodeStr, "@") of
                [_, Host] -> Host;
                _ ->
                    {ok, Hostname} = inet:gethostname(),
                    Hostname
            end
    end.

%% @private
%% Send a command to the C node and wait for response
send_command(CNodeName, Command) ->
    FullName = list_to_atom("c_" ++ atom_to_list(CNodeName) ++ "@" ++ get_hostname()),
    {any, FullName} ! Command,
    receive
        Reply -> Reply
    after 30000 ->
        {error, timeout}
    end.
