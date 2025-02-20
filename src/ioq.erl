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

-module(ioq).
-export([start/0, stop/0, call/3, call/4, call_search/3,
    set_disk_concurrency/1, get_disk_queues/0, get_osproc_queues/0,
    get_osproc_requests/0, get_disk_counters/0, get_disk_concurrency/0]).
-export([
    ioq2_enabled/0
]).
-export([get_io_priority/0, set_io_priority/1, maybe_set_io_priority/1]).
-export([bypass/2]).
-define(APPS, [config, couch_stats, ioq]).

set_io_priority(Priority) ->
    erlang:put(io_priority, Priority).

get_io_priority() ->
    erlang:get(io_priority).

maybe_set_io_priority(Priority) ->
    case get_io_priority() of
        undefined -> set_io_priority(Priority);
        _ -> ok
    end.

bypass(Msg, Priority) ->
    case ioq2_enabled() of
        false -> ioq_server:bypass(Msg, Priority);
        true  -> ioq_server2:bypass(Msg, Priority)
    end.

start() ->
    lists:foldl(fun(App, _) -> application:start(App) end, ok, ?APPS).

stop() ->
    lists:foldr(fun(App, _) -> ok = application:stop(App) end, ok, ?APPS).

call(Fd, Request, Arg, Priority) ->
    call(Fd, {Request, Arg}, Priority).

call(Pid, {prompt, _} = Msg, Priority) ->
    ioq_osq:call(Pid, Msg, Priority);
call(Pid, {data, _} = Msg, Priority) ->
    ioq_osq:call(Pid, Msg, Priority);
call(Fd, Msg, Priority) ->
    case ioq2_enabled() of
        false -> ioq_server:call(Fd, Msg, Priority);
        true  -> ioq_server2:call(Fd, Msg, Priority)
    end.

call_search(Fd, Msg, Priority) ->
    case ioq2_enabled() of
        false -> ioq_server:call(Fd, Msg, Priority);
        true  -> ioq_server2:call_search(Fd, Msg, Priority)
    end.

set_disk_concurrency(C) when is_integer(C), C > 0 ->
    case ioq2_enabled() of
        false -> gen_server:call(ioq_server, {set_concurrency, C});
        true  -> ioq_server2:set_concurrency(C)
    end;
set_disk_concurrency(_) ->
    erlang:error(badarg).

get_disk_concurrency() ->
    case ioq2_enabled() of
        false -> gen_server:call(ioq_server, get_concurrency);
        true  -> ioq_server2:get_concurrency()
    end.

get_disk_queues() ->
    case ioq2_enabled() of
        false -> gen_server:call(ioq_server, get_queue_depths);
        true  -> ioq_server2:get_queue_depths()
    end.

get_disk_counters() ->
    case ioq2_enabled() of
        false -> gen_server:call(ioq_server, get_counters);
        true  -> ioq_server2:get_counters()
    end.

get_osproc_queues() ->
    gen_server:call(ioq_osq, get_queue_depths).

get_osproc_requests() ->
    gen_server:call(ioq_osq, get_requests).

ioq2_enabled() ->
    config:get_boolean("ioq2", "enabled", false).

