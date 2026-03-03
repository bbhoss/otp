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

%% QUIC Application Module
%%
%% Provides application-level utilities and configuration for the QUIC
%% transport implementation. For the primary developer API, see gen_quic.

-module(quic).

-export([start/0, stop/0, versions/0]).

%% @doc Start the QUIC application and all dependencies.
-spec start() -> ok | {error, term()}.
start() ->
    case application:ensure_all_started(quic) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

%% @doc Stop the QUIC application.
-spec stop() -> ok | {error, term()}.
stop() ->
    application:stop(quic).

%% @doc Return supported QUIC versions.
-spec versions() -> [atom()].
versions() ->
    [quic_v1, quic_v2].
