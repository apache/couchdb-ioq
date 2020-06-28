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
-module(ioq_q).

-export([
    new/0,

    len/1,
    is_empty/1,

    in/2,
    out/1,

    to_list/1
]).


new() ->
    {ok, Q} = khash:new(),
    ok = khash:put(Q, next_id, 0),
    ok = khash:put(Q, oldest_id, undefined),
    Q.


len(Q) ->
    khash:size(Q) - 2. % two metadata keys


is_empty(Q) ->
    len(Q) == 0.


in(Item, Q) ->
    NextId = khash:get(Q, next_id),
    ok = khash:put(Q, NextId, Item),
    ok = khash:put(Q, next_id, NextId + 1),
    case khash:get(Q, oldest_id) of
        undefined ->
            khash:put(Q, oldest_id, NextId);
        _ ->
            ok
    end,
    Q.


out(Q) ->
    NextId = khash:get(Q, next_id),
    case khash:get(Q, oldest_id) of
        undefined ->
            {empty, Q};
        OldestId ->
            {value, Item} = khash:lookup(Q, OldestId),
            khash:del(Q, OldestId),
            case OldestId + 1 == NextId of
                true ->
                    % We've removed the last element in the queue
                    khash:put(Q, oldest_id, undefined);
                false ->
                    khash:put(Q, oldest_id, OldestId + 1)
            end,
            {{value, Item}, Q}
    end.


to_list(Q) ->
    Entries = khash:to_list(Q),
    NoMeta = [{K, V} || {K, V} <- Entries, is_integer(K)],
    Sorted = lists:sort(NoMeta),
    {_, Items} = lists:unzip(Sorted),
    Items.
