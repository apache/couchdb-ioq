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
-vsn(1).
-behaviour(config_listener).
-export([start_link/0, init/1]).
-export([get_ioq2_servers/0, get_all_ioq2_servers/0]).
-export([handle_config_change/5, handle_config_terminate/3]).
-export([processes/1]).

-include_lib("ioq/include/ioq.hrl").

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).
-define(CHILD_WITH_ARGS(I, Type, Args), {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ok = ioq_config_listener:subscribe(),
    IOQ2Children = ioq_server2_children(),
    {ok, {
        {one_for_one, 5, 10},
        [
            ?CHILD_WITH_ARGS(config_listener_mon, worker, [?MODULE, nil]),
            ?CHILD(ioq_server, worker),
            ?CHILD(ioq_osq, worker)
            | IOQ2Children
        ]
    }}.

ioq_server2_children() ->
    Name = ?IOQ2_SEARCH_SERVER,
    Search = {Name, {ioq_server2, start_link, [Name, search, false]}, permanent, 5000, worker, [Name]},
    Bind = config:get_boolean("ioq2", "bind_to_schedulers", false),
    [Search | ioq_server2_children(erlang:system_info(schedulers), Bind)].

ioq_server2_children(Count, Bind) ->
    lists:map(fun(I) ->
        Name = list_to_atom("ioq_server_" ++ integer_to_list(I)),
        {Name, {ioq_server2, start_link, [Name, I, Bind]}, permanent, 5000, worker, [Name]}
    end, lists:seq(1, Count)).

get_ioq2_servers() ->
    lists:map(fun(I) ->
        list_to_atom("ioq_server_" ++ integer_to_list(I))
    end, lists:seq(1, erlang:system_info(schedulers))).

get_all_ioq2_servers() ->
    [?IOQ2_SEARCH_SERVER | get_ioq2_servers()].

handle_config_change("ioq", _Key, _Val, _Persist, St) ->
    gen_server:cast(ioq_server, update_config),
    {ok, St};
handle_config_change("ioq2.search", _Key, _Val, _Persist, St) ->
    gen_server:cast(?IOQ2_SEARCH_SERVER, update_config),
    {ok, St};
handle_config_change("ioq2" ++ _, _Key, _Val, _Persist, St) ->
    lists:foreach(fun({_Id, Pid}) ->
        gen_server:cast(Pid, update_config)
    end, processes(ioq2)),
    {ok, St};
handle_config_change(_Sec, _Key, _Val, _Persist, St) ->
    {ok, St}.

handle_config_terminate(_Server, _Reason, _State) ->
    gen_server:cast(ioq_server, update_config),
    spawn(fun() ->
        lists:foreach(fun({_Id, Pid}) ->
            gen_server:cast(Pid, update_config)
        end, processes(ioq2))
    end),
    ok.

processes(ioq2) ->
    filter_children("^ioq_server_.*$");
processes(ioq) ->
    filter_children("^ioq_server$");
processes(config_listener_mon) ->
    filter_children("^config_listener_mon$");
processes(Arg) ->
    {error, [
        {expected_one_of, [ioq, ioq2, config_listener_mon]},
        {got, Arg}]}.

filter_children(RegExp) ->
    lists:filtermap(fun({Id, P, _, _}) ->
        case re:run(atom_to_list(Id), RegExp) of
            {match, _} -> {true, {Id, P}};
            _ -> false
        end
    end, supervisor:which_children(?MODULE)).
