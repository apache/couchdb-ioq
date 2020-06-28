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

-module(ioq_benchmark).


-export([
    default_opts/0,

    run/0,
    run/1,

    run_static/1,
    run_dynamic/1,

    analyze_priority/1
]).

-define(PIDS, ioq_benchmark_file_pids).
-define(WORKERS, ioq_benchmark_workers).

% Copied from ioq_server:
-record(request, {
    fd,
    msg,
    class,
    channel, % the name of the channel, not the actual data structure
    from,
    ref,
    t0,
    tsub
}).


default_opts() ->
    #{
        num_files => 10000,
        active_users => 2,
        static_load_to_drain => 200000,
        dynamic_load => #{
            initial_pids => 25,
            load_per_pid => 1000, % reqs/sec
            max_load => 500000, % reqs/sec
            ramp_delay => 10000, % msecs between pid spawning
            total_time => 600 % seconds
        },
        class_perc => #{
            customer => 0.75,
            replication => 0.10,
            compaction => 0.15,
            low => 0.0
        },
        op_perc => #{
            read => 0.334,
            write => 0.333,
            view => 0.333
        }
    }.


run() ->
    run(default_opts()).


run(Opts) ->
    io:format("Starting benchmark on: ~p~n", [self()]),
    ets:new(?PIDS, [public, set, named_table]),
    ets:new(?WORKERS, [public, set, named_table]),
    create_files(Opts),
    %run_static(Opts),
    run_dynamic(Opts).


run_static(Opts) ->
    pause_ioq_server(),
    generate_static_load(Opts),
    unpause_ioq_server(),
    T0 = os:timestamp(),
    wait_for_empty(T0, Opts),
    USecDiff = timer:now_diff(os:timestamp(), T0),
    io:format("Static Test: ~.3f~n", [USecDiff / 1000000]).


run_dynamic(Opts) ->
    T0 = os:timestamp(),
    spawn_link(fun() -> load_spawner(Opts, T0) end),
    monitor_dynamic(Opts, T0).


load_spawner(Opts, T0) ->
    #{
        dynamic_load := #{
            initial_pids := InitialPids,
            load_per_pid := LoadPerPid,
            max_load := MaxLoad,
            ramp_delay := RampDelay,
            total_time := TotalTime
        }
    } = Opts,

    % Fill up our initial pids
    ToSpawn = max(0, InitialPids - ets:info(?WORKERS, size)),
    lists:foreach(fun(_) ->
        Pid = spawn_link(fun() -> worker_loop(Opts, T0) end),
        ets:insert(?WORKERS, {Pid, true})
    end, lists:seq(1, ToSpawn)),

    % Spawn a worker if we have room
    MaxPids = MaxLoad div LoadPerPid,
    HasMaxWorkers = MaxPids < ets:info(?WORKERS, size),
    if HasMaxWorkers -> ok; true ->
        Pid = spawn_link(fun() -> worker_loop(Opts, T0) end),
        ets:insert(?WORKERS, {Pid, true})
    end,

    % If we have more time, wait and recurse
    OutOfTime = timer:now_diff(os:timestamp(), T0) div 1000000 > TotalTime,
    if OutOfTime -> ok; true ->
        timer:sleep(RampDelay),
        load_spawner(Opts, T0)
    end.


worker_loop(Opts, T0) ->
    #{
        dynamic_load := #{
            load_per_pid := LoadPerPid,
            total_time := TotalTime
        }
    } = Opts,

    drain_msgs(),

    % We can only sleep for a minimum of 1ms
    {Msgs, Sleep} = case LoadPerPid > 1000 of
        true -> {LoadPerPid div 1000, 1};
        false -> {1, 1000 div LoadPerPid}
    end,

    generate_static_load(Msgs, Opts),

    % If we have more time, wait and recurse
    OutOfTime = timer:now_diff(os:timestamp(), T0) div 1000000 > TotalTime,
    if OutOfTime -> ok; true ->
        timer:sleep(Sleep),
        worker_loop(Opts, T0)
    end.


drain_msgs() ->
    receive
        _ ->
            drain_msgs()
    after 0 ->
        ok
    end.


monitor_dynamic(Opts, T0) ->
    #{
        dynamic_load := #{
            load_per_pid := LoadPerPid,
            total_time := TotalTime
        }
    } = Opts,

    T2 = timer:now_diff(os:timestamp(), T0),
    [{_, MQL}, {_, THS}, {_, GCI}] = process_info(whereis(ioq_server), [
        message_queue_len,
        total_heap_size,
        garbage_collection_info
    ]),
    {_, RecentSize} = lists:keyfind(recent_size, 1, GCI),
    NumWorkers = ets:info(?WORKERS, size),
    Load = NumWorkers * LoadPerPid,
    io:format("~.3f,~p,~p,~p,~p~n", [T2 / 1000000, Load, MQL, THS, RecentSize]),

    OutOfTime = timer:now_diff(os:timestamp(), T0) div 1000000 > TotalTime,
    if OutOfTime -> ok; true ->
        timer:sleep(1000),
        monitor_dynamic(Opts, T0)
    end.


create_files(#{num_files := NumFiles}) when NumFiles > 0 ->
    create_files(NumFiles);

create_files(NumFiles) when NumFiles > 0 ->
    Pid = spawn(fun() -> file_loop() end),
    ets:insert(?PIDS, {NumFiles - 1, Pid}),
    create_files(NumFiles - 1);

create_files(0) ->
    ok.


file_loop() ->
    receive
        {'$gen_call', From, _IoMsg} ->
            io_wait(),
            gen:reply(From, ok)
    end,
    file_loop().


io_wait() ->
    case rand:uniform() > 0.33 of
        true ->
            timer:sleep(1);
        false ->
            ok
    end.


pause_ioq_server() ->
    erlang:suspend_process(whereis(ioq_server)).


unpause_ioq_server() ->
    erlang:resume_process(whereis(ioq_server)).


generate_static_load(Opts) ->
    #{
        static_load_to_drain := Load
    } = Opts,
    generate_static_load(Load, Opts).


generate_static_load(Load, Opts) when Load > 0 ->
    #{
        num_files := NumFiles,
        active_users := Users,
        class_perc := ClassPerc,
        op_perc := OpPerc
    } = Opts,

    Id = trunc(rand:uniform() * NumFiles),
    [{Id, Pid}] = ets:lookup(?PIDS, Id),
    User = trunc(rand:uniform() * Users),
    UserBin = integer_to_binary(User),
    {IoPriority, IoMsg} = gen_priority_and_message(UserBin, ClassPerc, OpPerc),
    do_call(Pid, IoMsg, IoPriority),
    generate_static_load(Load - 1, Opts);

generate_static_load(0, _) ->
    ok.


do_call(Pid, IoMsg, IoPriority) ->
    {Class, Channel} = analyze_priority(IoPriority),
    Request = #request{
        fd = Pid,
        msg = IoMsg,
        channel = Channel,
        class = Class,
        t0 = erlang:monotonic_time()
    },
    % ioq_server:call(Pid, IoMsg, IoPriority).
    Mref = erlang:make_ref(),
    Msg = {'$gen_call', {self(), Mref}, Request},
    erlang:send(whereis(ioq_server), Msg).


wait_for_empty(T0, #{static_load_to_drain := Load}) ->
    wait_for_empty_int(T0, Load).


wait_for_empty_int(T0, Remain) when Remain > 0 ->
    receive
        _Msg ->
            case (Remain rem 1000) == 0 of
                true ->
                    T2 = timer:now_diff(os:timestamp(), T0),
                    {_, MQL} = process_info(whereis(ioq_server), message_queue_len),
                    io:format("~.3f,~p,~p~n", [T2 / 1000000, Remain, MQL]);
                false ->
                    ok
            end,
            wait_for_empty_int(T0, Remain - 1)
    after 1000 ->
        T1 = timer:now_diff(os:timestamp(), T0),
        {_, MQL} = process_info(whereis(ioq_server), message_queue_len),
        io:format("~.3f,~p,~p~n", [T1 / 1000000, Remain, MQL]),
        wait_for_empty_int(T0, Remain)
    end;

wait_for_empty_int(_T0, 0) ->
    ok.


gen_priority_and_message(UserBin, ClassPerc, OpPerc) ->
    Class = map_choice(ClassPerc),
    IoType = case Class of
        customer ->
            case map_choice(OpPerc) of
                read ->
                    interactive;
                write ->
                    db_update;
                view ->
                    view_update
            end;
        compaction ->
            case rand:uniform() < 0.5 of
                true -> db_compact;
                false -> view_compact
            end;
        replication ->
            internal_repl;
        low ->
            low
    end,
    IoMsg = case map_choice(OpPerc) of
        read ->
            {pread_iolist, rand:uniform()};
        write ->
            {append_binary, rand:uniform()};
        view ->
            case rand:uniform() < 0.6 of
                true ->
                    {pread_iolist, rand:uniform()};
                false ->
                    {append_binary, rand:uniform()}
            end
    end,
    {{IoType, <<"shards/00000000-ffffffff/", UserBin/binary, "/foo">>}, IoMsg}.


map_choice(#{} = Choices) ->
    KVs = maps:to_list(Choices),
    Sorted = lists:sort([{V, K} || {K, V} <- KVs]),
    choose(Sorted, rand:uniform()).


choose([{Perc, Item}], RandVal) when RandVal =< Perc ->
    Item;
choose([{Perc, Item} | _Rest], RandVal) when RandVal < Perc ->
    Item;
choose([{Perc, _Item} | Rest], RandVal) ->
    choose(Rest, RandVal - Perc).

% Copied from ioq_server
analyze_priority({interactive, Shard}) ->
    {interactive, channel_name(Shard)};
analyze_priority({db_update, Shard}) ->
    {db_update, channel_name(Shard)};
analyze_priority({view_update, Shard, _GroupId}) ->
    {view_update, channel_name(Shard)};
analyze_priority({db_compact, _Shard}) ->
    {db_compact, nil};
analyze_priority({view_compact, _Shard, _GroupId}) ->
    {view_compact, nil};
analyze_priority({internal_repl, _Shard}) ->
    {internal_repl, nil};
analyze_priority({low, _Shard}) ->
    {low, nil};
analyze_priority(_Else) ->
    {other, other}.

channel_name(Shard) ->
    try split(Shard) of
    [<<"shards">>, _, <<"heroku">>, AppId | _] ->
        <<AppId/binary, ".heroku">>;
    [<<"shards">>, _, DbName] ->
        ioq_kv:get({other, DbName}, other);
    [<<"shards">>, _, Account, DbName] ->
        ioq_kv:get({Account, DbName}, Account);
    [<<"shards">>, _, Account | DbParts] ->
        ioq_kv:get({Account, filename:join(DbParts)}, Account);
    _ ->
        other
    catch _:_ ->
        other
    end.


split(B) when is_binary(B) ->
    split(B, 0, 0, []);
split(B) -> B.

split(B, O, S, Acc) ->
    case B of
    <<_:O/binary>> ->
        Len = O - S,
        <<_:S/binary, Part:Len/binary>> = B,
        lists:reverse(Acc, [Part]);
    <<_:O/binary, $/, _/binary>> ->
        Len = O - S,
        <<_:S/binary, Part:Len/binary, _/binary>> = B,
        split(B, O+1, O+1, [Part | Acc]);
    _ ->
        split(B, O+1, S, Acc)
    end.