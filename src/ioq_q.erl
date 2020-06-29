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

    lookup/2,
    put/3,
    del/2,

    to_list/1
]).


new() ->
    {ok, Q} = khash:new(),
    {ok, H} = khash:new(),
    ok = khash:put(Q, next_id, 0),
    ok = khash:put(Q, oldest_id, undefined),
    {Q, H}.


len({Q, _}) ->
    khash:size(Q) - 2. % two metadata keys


is_empty({Q, H}) ->
    len({Q, H}) == 0.


in(Item, {Q, H}) ->
    NextId = khash:get(Q, next_id),
    ok = khash:put(Q, NextId, Item),
    ok = khash:put(Q, next_id, NextId + 1),
    case khash:get(Q, oldest_id) of
        undefined ->
            khash:put(Q, oldest_id, NextId);
        _ ->
            ok
    end,
    {Q, H}.


out({Q, H}) ->
    NextId = khash:get(Q, next_id),
    case khash:get(Q, oldest_id) of
        undefined ->
            {empty, {Q, H}};
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
            {{value, Item}, {Q, H}}
    end.


lookup({_Q, H}, Key) ->
    khash:lookup(H, Key).


put({Q, H}, Key, Value) ->
    khash:put(H, Key, Value),
    {Q, H}.


del({Q, H}, Key) ->
    khash:del(H, Key),
    {Q, H}.


to_list({Q, _H}) ->
    Entries = khash:to_list(Q),
    NoMeta = [{K, V} || {K, V} <- Entries, is_integer(K)],
    Sorted = lists:sort(NoMeta),
    {_, Items} = lists:unzip(Sorted),
    Items.
