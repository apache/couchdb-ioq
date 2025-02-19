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

-module(ioq_config_tests).


-include_lib("ioq/include/ioq.hrl").
-include_lib("couch/include/couch_eunit.hrl").


-define(USERS_CONFIG, [{"bar","2.4"},{"baz","4.0"},{"foo","1.2"}]).
-define(CLASSES_CONFIG, [{"view_compact","2.4"},{"db_update","1.9"}]).
-define(SHARDS_CONFIG, [
    {
        {<<"shards/00000000-1fffffff/foo/pizza_db">>, db_update},
        5.0
    },
    {
        {<<"shards/00000000-1fffffff/foo/pizza_db">>, view_update},
        7.0
    }
]).

config_update_test_() ->
    {
        "Test config updates",
        {
            foreach,
            fun() ->
                meck:expect(couch_log, notice, fun(_, _) -> ok end),
                test_util:start_applications([config, ioq])
            end,
            fun(Apps) ->
                test_util:stop_applications(Apps),
                meck:unload()
            end,
            [
                ?TDEF_FE(t_restart_config_listener),
                ?TDEF_FE(t_update_ioq_config),
                ?TDEF_FE(t_update_ioq2_config),
                ?TDEF_FE(t_update_ioq_config_on_listener_restart),
                ?TDEF_FE(t_update_ioq2_config_on_listener_restart)
            ]
        }
}.

t_restart_config_listener(_) ->
    [{_, ConfigMonitor}] = ioq_sup:processes(config_listener_mon),
    ?assert(is_process_alive(ConfigMonitor)),
    test_util:stop_sync(ConfigMonitor),
    ?assertNot(is_process_alive(ConfigMonitor)),
    NewConfigMonitor = test_util:wait(fun() ->
        case ioq_sup:processes(config_listener_mon) of
            [] -> wait;
            [{_, Pid}] -> Pid
        end
    end),
    ?assert(is_process_alive(NewConfigMonitor)).


t_update_ioq_config(_) ->
    [{_, IoqServer}] = ioq_sup:processes(ioq),
    gen_server:call(IoqServer, {set_concurrency, 10}),
    ?assertEqual(10, gen_server:call(IoqServer, get_concurrency)),
    ?assert(is_process_alive(IoqServer)),
    config:set("ioq", "concurrency", "200", false),
    ?assertNotEqual(timeout, test_util:wait(fun() ->
        case gen_server:call(IoqServer, get_concurrency) of
            200 -> 200;
            _ -> wait
        end
    end)),
    ?assert(is_process_alive(IoqServer)).

t_update_ioq_config_on_listener_restart(_) ->
    [{_, IoqServer}] = ioq_sup:processes(ioq),
    DefaultConcurrency = gen_server:call(IoqServer, get_concurrency),
    gen_server:call(IoqServer, {set_concurrency, 10}),
    ?assertEqual(10, gen_server:call(IoqServer, get_concurrency)),
    ?assert(is_process_alive(IoqServer)),

    [{_, ConfigMonitor}] = ioq_sup:processes(config_listener_mon),
    ?assert(is_process_alive(ConfigMonitor)),
    test_util:stop_sync(ConfigMonitor),

    ?assertNotEqual(timeout, test_util:wait(fun() ->
        case gen_server:call(IoqServer, get_concurrency) of
            DefaultConcurrency -> ok;
            _ -> wait
        end
    end)),
    ?assert(is_process_alive(IoqServer)).

t_update_ioq2_config(_) ->
    [{_, IoqServer} | _] = ioq_sup:processes(ioq2),
    gen_server:call(IoqServer, {set_concurrency, 10}),
    ?assertEqual(10, gen_server:call(IoqServer, get_concurrency)),
    ?assert(is_process_alive(IoqServer)),
    config:set("ioq2", "concurrency", "200", false),
    ?assertNotEqual(timeout, test_util:wait(fun() ->
        case gen_server:call(IoqServer, get_concurrency) of
            200 -> 200;
            _ -> wait
        end
    end)),
    ?assert(is_process_alive(IoqServer)).

t_update_ioq2_config_on_listener_restart(_) ->
    [{_, IoqServer} | _] = ioq_sup:processes(ioq2),
    DefaultConcurrency = gen_server:call(IoqServer, get_concurrency),
    gen_server:call(IoqServer, {set_concurrency, 10}),
    ?assertEqual(10, gen_server:call(IoqServer, get_concurrency)),
    ?assert(is_process_alive(IoqServer)),

    [{_, ConfigMonitor}] = ioq_sup:processes(config_listener_mon),
    ?assert(is_process_alive(ConfigMonitor)),
    test_util:stop_sync(ConfigMonitor),

    ?assertNotEqual(timeout, test_util:wait(fun() ->
        case gen_server:call(IoqServer, get_concurrency) of
            DefaultConcurrency -> ok;
            _ -> wait
        end
    end)),
    ?assert(is_process_alive(IoqServer)).

priorities_test_() ->
    {ok, ShardP} = ioq_config:build_shard_priorities(?SHARDS_CONFIG),
    {ok, UserP} = ioq_config:build_user_priorities(?USERS_CONFIG),
    {ok, ClassP} = ioq_config:build_class_priorities(?CLASSES_CONFIG),
    Tests = [
        %% {User, Shard, Class, UP * SP * CP}
        {<<"foo">>, <<"shards/00000000-1fffffff/foo/pizza_db">>, db_update, 1.2 * 5.0 * 1.9},
        {<<"foo">>, <<"shards/00000000-1fffffff/foo/pizza_db">>, view_update, 1.2 * 7.0 * 1.0},
        {<<"foo">>, <<"shards/00000000-1fffffff/foo/pizza_db">>, view_compact, 1.2 * 1.0 * 2.4},
        {<<"foo">>, <<"shards/00000000-1fffffff/foo/pizza_db">>, db_compact, 1.2 * 1.0 * 0.0001},
        {<<"foo">>, <<"shards/00000000-1fffffff/foo/pizza_db">>, internal_repl, 1.2 * 1.0 * 0.001},
        {<<"baz">>, undefined, internal_repl, 4 * 1.0 * 0.001}
    ],
    lists:map(
        fun({User, Shard, Class, Priority}) ->
            Req = #ioq_request{user=User, shard=Shard, class=Class},
            ?_assertEqual(
                Priority,
                ioq_config:prioritize(Req, ClassP, UserP, ShardP)
            )
        end,
        Tests
    ).


parse_shard_string_test() ->
    Shard = "shards/00000000-1fffffff/foo/pizza_db",
    Classes = ["db_update", "view_update", "view_compact", "db_compact"],
    lists:map(
        fun(Class) ->
            ShardString = Shard ++ "||" ++ Class,
            ?assertEqual(
                {list_to_binary(Shard), list_to_existing_atom(Class)},
                ioq_config:parse_shard_string(ShardString)
            )
        end,
        Classes
    ).


parse_bad_string_test() ->
    Shard = "shards/00000000-1fffffff/foo/pizza_db$$$$$ASDF",
    ?assertEqual(
        {error, Shard},
        ioq_config:parse_shard_string(Shard)
    ).


to_float_test_() ->
    Default = 123456789.0,
    Tests = [
        {0.0, 0},
        {0.0, "0"},
        {1.0, "1"},
        {1.0, 1},
        {7.9, 7.9},
        {7.9, "7.9"},
        {79.0, "79"},
        {Default, "asdf"}
    ],
    [?_assertEqual(E, ioq_config:to_float(T, Default)) || {E, T} <- Tests].


config_set_test_() ->
    {
        "Test ioq_config setters",
        {
            foreach,
            fun() ->
                meck:expect(couch_log, notice, fun(_, _) -> ok end),
                test_util:start_applications([config])
            end,
            fun(_) ->
                test_util:stop_applications([config]),
                meck:unload()
            end,
            [
                ?TDEF_FE(check_simple_configs),
                ?TDEF_FE(check_bypass_configs)
            ]
        }
    }.


check_simple_configs(_) ->
    Defaults = [
        {"concurrency", "1"},
        {"resize_limit", "1000"},
        {"dedupe", "true"},
        {"scale_factor", "2.0"},
        {"max_priority", "10000.0"},
        {"enabled", "false"},
        {"dispatch_strategy", ?DISPATCH_SERVER_PER_SCHEDULER}
    ],
    SetTests = [
        {set_concurrency, 9, "9"},
        {set_resize_limit, 8888, "8888"},
        {set_dedupe, false, "false"},
        {set_scale_factor, 3.14, "3.14"},
        {set_max_priority, 99999.99, "99999.99"},
        {set_enabled, true, "true"},
        {set_dispatch_strategy,
            ?DISPATCH_FD_HASH, atom_to_list(?DISPATCH_FD_HASH)}
    ],

    Reason = "ioq_config_tests",
    %% Custom assert for handling floats as strings
    Assert = fun(Expected0, Value0) ->
        ?assertEqual(
            ioq_config:to_float(Expected0, Expected0),
            ioq_config:to_float(Value0, Value0)
        )
    end,

    Tests0 = lists:map(fun({Key, Default}) ->
        Value = config:get("ioq2", Key, Default),
        ?assertEqual(Default, Value)
    end, Defaults),

    lists:foldl(fun({Fun, Value, Result}, Acc) ->
        ok = ioq_config:Fun(Value, Reason),
        Key = lists:sublist(atom_to_list(Fun), 5, 9999),
        Value1 = config:get("ioq2", Key, undefined),
        [Assert(Result, Value1) | Acc]
    end, Tests0, SetTests).


check_bypass_configs(_) ->
    Shard = <<"shards/00000000-1fffffff/foo/pizza_db">>,

    ?assertNot(ioq:bypass({'$gen_call', fd, foo}, {interactive, Shard})),
    ?assertNot(ioq:bypass({'$gen_call', fd, foo}, {db_commpact, Shard})),

    % ioq 1
    ?assertNot(ioq:ioq2_enabled()),
    config:set("ioq.bypass", "interactive", "true", false),
    ?assert(ioq:bypass({'$gen_call', fd, foo}, {interactive, Shard})),
    ?assertNot(ioq:bypass({'$gen_call', fd, foo}, {db_commpact, Shard})),

    % ioq 2
    config:set("ioq2", "enabled", "true", false),
    ?assert(ioq:ioq2_enabled()),
    ok = ioq_config:set_bypass(interactive, true, "Bypassing interactive"),
    ?assert(config:get_boolean("ioq2.bypass", "interactive", false)),

    ?assert(ioq:bypass({'$gen_call', fd, foo}, {interactive, Shard})),
    ?assertNot(ioq:bypass({'$gen_call', fd, foo}, {db_commpact, Shard})),

    config:delete("ioq2", "enabled", false),
    config:delete("ioq.bypass", "interactive", false),
    config:delete("ioq2.bypass", "interactive", false).


valid_classes_test_() ->
    {
        "Test ioq_config is_valid_class logic",
        {
            foreach,
            fun() ->
                meck:expect(couch_log, notice, fun(_, _) -> ok end),
                test_util:start_applications([config])
            end,
            fun(_) ->
                test_util:stop_applications([config]),
                meck:unload()
            end,
            [
                ?TDEF_FE(check_default_classes),
                ?TDEF_FE(check_undeclared_class),
                ?TDEF_FE(check_declared_class)
            ]
        }
    }.


check_default_classes(_) ->
    Classes = [C || {C, _P} <- ?DEFAULT_CLASS_PRIORITIES],
    [?assert(ioq_config:is_valid_class(C)) || C <- Classes].


check_undeclared_class(_) ->
    ?assert(not ioq_config:is_valid_class(external)).


check_declared_class(_) ->
    config:set(?IOQ2_CLASSES_CONFIG, "search", "1.0", false),
    ?assert(ioq_config:is_valid_class(search)).
