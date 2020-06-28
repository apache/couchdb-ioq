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

-module(ioq_q_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NUM_ITERATIONS, 10000).

-record(st, {
    ioq_q = ioq_q:new(),
    erl_q = queue:new()
}).


q_fuzz_test() ->
    Ops = #{
        len => 0.2,
        is_empty => 0.1,
        in => 0.4,
        out => 0.2,
        to_list => 0.1
    },
    FinalSt = lists:foldl(fun(_Iter, St) ->
        Op = map_choice(Ops),
        #st{
            ioq_q = IOQQ,
            erl_q = ErlQ
        } = St,
        %?debugFmt("~nOp: ~p~n~p~n~p~n", [Op, ioq_q:to_list(IOQQ), queue:to_list(ErlQ)]),
        case Op of
            in ->
                Item = new_item(),
                #st{
                    ioq_q = ioq_q:in(Item, IOQQ),
                    erl_q = queue:in(Item, ErlQ)
                };
            out ->
                {R1, NewIOQQ} = ioq_q:out(IOQQ),
                {R2, NewErlQ} = queue:out(ErlQ),
                ?assertEqual(R2, R1),
                #st{
                    ioq_q = NewIOQQ,
                    erl_q = NewErlQ
                };
            _ ->
                R1 = ioq_q:Op(IOQQ),
                R2 = queue:Op(ErlQ),
                ?assertEqual(R2, R1),
                St
        end
    end, #st{}, lists:seq(1, ?NUM_ITERATIONS)),
    check_drain(FinalSt).


check_drain(#st{ioq_q = IOQQ, erl_q = ErlQ}) ->
    {R1, NewIOQQ} = ioq_q:out(IOQQ),
    {R2, NewErlQ} = queue:out(ErlQ),
    ?assertEqual(R2, R1),
    case R1 == empty of
        true ->
            ok;
        false ->
            check_drain(#st{ioq_q = NewIOQQ, erl_q = NewErlQ})
    end.


new_item() ->
    rand:uniform().


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
