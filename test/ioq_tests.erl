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

-module(ioq_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("ioq/include/ioq.hrl").

all_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun instantiate/1}.

setup() ->
    Apps = test_util:start_applications([
        config, couch_log, couch_stats, ioq
    ]),
    FakeServer = fun(F) ->
        receive {'$gen_call', {Pid, Ref}, Call} ->
            Pid ! {Ref, {reply, Call}}
        end,
        F(F)
    end,
    {Apps, spawn(fun() -> FakeServer(FakeServer) end)}.

cleanup({Apps, Server}) ->
    test_util:stop_applications(Apps),
    exit(Server, kill).

instantiate({_, S}) ->
    Old = case ioq:ioq2_enabled() of
        true ->
            ?DEFAULT_IOQ2_CONCURRENCY * length(ioq_sup:get_ioq2_servers());
        false ->
            20
    end,
    [{inparallel, lists:map(fun(IOClass) ->
        lists:map(fun(Shard) ->
            check_call(S, make_ref(), priority(IOClass, Shard))
        end, shards())
    end, io_classes())},
    ?_assertEqual(Old, ioq:set_disk_concurrency(10)),
    ?_assertError(badarg, ioq:set_disk_concurrency(0)),
    ?_assertError(badarg, ioq:set_disk_concurrency(-1)),
    ?_assertError(badarg, ioq:set_disk_concurrency(foo))].

check_call(Server, Call, Priority) ->
    ?_assertEqual({reply, Call}, ioq:call(Server, Call, Priority)).

io_classes() -> [interactive, view_update, db_compact, view_compact,
    internal_repl, other, search, system, reshard].

shards() ->
    [
        <<"shards/0-1/heroku/app928427/couchrest.1317609656.couch">>,
        <<"shards/0-1/foo">>,
        <<"shards/0-3/foo">>,
        <<"shards/0-1/bar">>,
        <<"shards/0-1/kocolosk/stats.1299297461.couch">>,
        <<"shards/0-1/kocolosk/my/db.1299297457.couch">>,
        other
    ].

priority(view_update, Shard) ->
    {view_update, Shard, <<"_design/foo">>};
priority(Any, Shard) ->
    {Any, Shard}.
