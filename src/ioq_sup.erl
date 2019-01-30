% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(ioq_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
-export([get_ioq2_servers/0]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ok = ioq_config_listener:subscribe(),
    IOQ2Children = ioq_server2_children(),
    {ok, {
        {one_for_one, 5, 10},
        [
            ?CHILD(ioq_server, worker),
            ?CHILD(ioq_osq, worker)
            | IOQ2Children
        ]
    }}.

ioq_server2_children() ->
    Bind = config:get_boolean("ioq2", "bind_to_schedulers", false),
    ioq_server2_children(erlang:system_info(schedulers), Bind).

ioq_server2_children(Count, Bind) ->
    lists:map(fun(I) ->
        Name = list_to_atom("ioq_server_" ++ integer_to_list(I)),
        {Name, {ioq_server2, start_link, [Name, I, Bind]}, permanent, 5000, worker, [Name]}
    end, lists:seq(1, Count)).

get_ioq2_servers() ->
    lists:map(fun(I) ->
        list_to_atom("ioq_server_" ++ integer_to_list(I))
    end, lists:seq(1, erlang:system_info(schedulers))).
