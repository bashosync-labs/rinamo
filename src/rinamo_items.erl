%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------

-module(rinamo_items).

-export([
    put_item/4,
    get_item/3,
    delete_item/3,
    query/4]).

-include("rinamo.hrl").

-spec put_item(binary(), any(), any(), #state{ owner_key :: binary() }) -> ok.
put_item(Table, Item, Expectations, AWSContext) ->
    UserKey = AWSContext#state.owner_key,
    % TODO:  expectations (conditional puts)
    StrongConsistency = case Expectations of
        [{FieldName, [{<<"Exists">>, Expected}, {FieldType, FieldValue}]}] ->
            true;
        _ ->
            false
    end,
    lager:debug("Using Strong Consistency: ~p~n", [StrongConsistency]),
    [{table_keyschema, KeySchema},
     {lsi, LSI},
     {gsi, GSI}] = get_table_info(Table, AWSContext),
    _ = case KeySchema of
        [{HashKeyAttribute, hash}] ->
            [{_, HashKeyValue}] = kvc:path(HashKeyAttribute, Item),
            store_hash_key(UserKey, Table, HashKeyValue, Item);
        [{HashKeyAttribute, hash}, {RangeKeyAttribute, range}] ->
            [{_, HashKeyValue}] = kvc:path(HashKeyAttribute, Item),
            [{_, RangeKeyValue}] = kvc:path(RangeKeyAttribute, Item),
            store_range_key(UserKey, Table, RangeKeyAttribute, HashKeyValue, RangeKeyValue, Item)
    end,
    _ = store_lsi(UserKey, Table, LSI, Item),
    _ = store_gsi(UserKey, Table, GSI, Item),

    ok.

-spec get_item(binary(), binary(), #state{ owner_key :: binary() }) -> any().
get_item(Table, Key, AWSContext) ->
    UserKey = AWSContext#state.owner_key,
    B = erlang:iolist_to_binary([UserKey, ?RINAMO_SEPARATOR, Table]),

    {_, Item_V} = rinamo_kv:get(rinamo_kv:client(), B, Key),

    case Item_V of
        {insufficient_vnodes, _, _, _} -> throw(insufficient_vnodes_available);
        notfound -> notfound;
        _ -> jsx:decode(Item_V)
    end.

-spec delete_item(binary(), binary(), #state{ owner_key :: binary() }) -> ok.
delete_item(Table, Key, AWSContext) ->
    UserKey = AWSContext#state.owner_key,
    _ = case Key of
        [{_, {_, HashKeyVal}}] ->
            B = erlang:iolist_to_binary([UserKey, ?RINAMO_SEPARATOR, Table]),
            rinamo_kv:delete(rinamo_kv:client(), B, HashKeyVal);
        [{_, {_, HashKeyVal}}, {RangeKeyAttribute, {_, RangeKeyVale}}] ->
            % ------- begin index concern
            % ------- end index concern
            ok
    end,

    ok.

query(Table, IndexName, KeyConditions, AWSContext) ->
    UserKey = AWSContext#state.owner_key,

    MappedConditions = map_key_conditions(Table, IndexName, KeyConditions, AWSContext),
    % TODO: Validation
    %  - lsi_same_hashkey
    %  - too_many_conditions
    case MappedConditions of
        [{hash, {_, [{_, HashKeyValue}], _}},
         {remaining, _}] ->
             [get_item(Table, HashKeyValue, AWSContext)];
        [{hash, {_, [{_, HashKeyValue}], _}},
         {range, {RangeKeyAttr, RangeKeyOperands, RangeKeyOperator}},
         {remaining, PostFilterConditions}] ->
            PartitionNS = case is_binary(IndexName) of
                true ->
                    [UserKey, ?RINAMO_SEPARATOR, Table, ?RINAMO_SEPARATOR, IndexName, ?RINAMO_SEPARATOR, RangeKeyAttr];
                false ->
                    [UserKey, ?RINAMO_SEPARATOR, Table, ?RINAMO_SEPARATOR, RangeKeyAttr]
            end,
            % ------- begin index concern

            M = rinamo_config:get_index_strategy(),
            F = query,
            A = [
                erlang:iolist_to_binary(PartitionNS),
                HashKeyValue,
                {RangeKeyAttr, RangeKeyOperands, RangeKeyOperator},
                PostFilterConditions
            ],
            lager:debug("Index Strat: ~p~n", [M]),
            erlang:apply(M, F, A);

            % ------- end index concern
        _ ->
            % a result of not doing enough validation
            lager:debug("MappedConditions: ~p~n", [MappedConditions]),
            throw(internal_failure)
    end.

%% Internal

-spec store_hash_key(binary(), binary(), [binary()], binary()) -> ok.
store_hash_key(_, _, [], _) ->
    ok;
store_hash_key(User, Table, [Key|Rest], Item) ->
    store_hash_key(User, Table, Rest, Item),
    store_hash_key(User, Table, Key, Item);
store_hash_key(User, Table, Key, Item) ->
    lager:debug("Storing as Hash Key: ~p:", [Key]),

    B = erlang:iolist_to_binary([User, ?RINAMO_SEPARATOR, Table]),
    Value = jsx:encode(Item),

    _ = rinamo_kv:put(rinamo_kv:client(), B, Key, Value, "application/json"),
    ok.

store_range_key(UserKey, Table, RangeKeyAttribute, HashKeyValue, RangeKeyValue, Item) ->
    lager:debug("Storing as Range Key: ~p::~p:", [HashKeyValue, RangeKeyValue]),

    % ------- begin index concern

    M = rinamo_config:get_index_strategy(),
    F = store,
    A = [
        erlang:iolist_to_binary([UserKey, ?RINAMO_SEPARATOR, Table, ?RINAMO_SEPARATOR, RangeKeyAttribute]),
        HashKeyValue,
        RangeKeyValue,
        Item
    ],
    _ = erlang:apply(M, F, A),

    % ------- end index concern

    ok.

store_lsi(UserKey, Table, [Index|Rest], Item) ->
    [{<<"IndexName">>, IndexName},
     {<<"KeySchema">>, IKeySchema},
     {<<"Projection">>, _}] = Index,

    write_index_value(UserKey, Table, IndexName, IKeySchema, Item),
    store_lsi(UserKey, Table, Rest, Item);
store_lsi(_, _, [], _) ->
    ok.

store_gsi(UserKey, Table, [Index|Rest], Item) ->
    [{<<"IndexName">>, IndexName},
     {<<"KeySchema">>, IKeySchema},
     {<<"Projection">>, _},
     {<<"ProvisionedThroughput">>, _}] = Index,

    write_index_value(UserKey, Table, IndexName, IKeySchema, Item),
    store_gsi(UserKey, Table, Rest, Item);
store_gsi(_, _, [], _) ->
    ok.


% TODO: do something more interesting with Projection
%   - NonKeyAttributes are optional
%[{<<"ProjectionType">>, ProjectionType},
% {<<"NonKeyAttributes">>, NonKeyAttributes}] = Projection
write_index_value(UserKey, Table, IndexName, IKeySchema, Item) ->
    KeySchema = map_key_types(IKeySchema, []),
    _ = case KeySchema of
        [{HashKeyAttribute, hash}] ->
            % TODO: handle this direct hash key case, workaround for not
            % having actual columns in Riak
            ok;
        [{HashKeyAttribute, hash}, {RangeKeyAttribute, range}] ->
            IndexAndRangeAttr = erlang:iolist_to_binary([IndexName, ?RINAMO_SEPARATOR, RangeKeyAttribute]),
            [{_, HashKeyValue}] = kvc:path(HashKeyAttribute, Item),
            case kvc:path(RangeKeyAttribute, Item) of
                [{_, RangeKeyValue}] ->
                    store_range_key(UserKey, Table, IndexAndRangeAttr, HashKeyValue, RangeKeyValue, Item);
                [] -> ok;
                _ -> ok
            end;
        _ ->
            % error?
            ok
        end.


% table_keyschema is a sorted tuple array.  Callers may pattern match on
% [{hash, HashAttr}] or [{hash, HashAttr}, {range, RangeAttr}]
%
% lsi & gsi is a list of index info
-spec get_table_info(binary(), #state{ owner_key :: binary() }) -> [tuple()].
get_table_info(Table, AWSContext) when is_binary(Table) ->
    TD = rinamo_tables:load_table_def(Table, AWSContext),
    case TD of
      notfound -> throw(table_missing);
      _ ->[{table_keyschema, map_key_types(kvc:path("KeySchema", TD), [])},
           {lsi, kvc:path("LocalSecondaryIndexes", TD)},
           {gsi, kvc:path("GlobalSecondaryIndexes", TD)}]
    end.

% map attribute name to keytype for easier matching later
map_key_types([Attribute|Rest], Acc) ->
    % handle cases where attribute type and key type are out of order within
    % a single key definition.
    % (attribute_name should come before key_type)
    OrderedAttr = lists:keysort(1, Attribute),
    [{_, AttributeName}, {_, KeyType}] = OrderedAttr,
    KeyTypeAtom = erlang:list_to_atom(string:to_lower(erlang:binary_to_list(KeyType))),
    map_key_types(Rest, [{AttributeName, KeyTypeAtom} | Acc]);
map_key_types([], Acc) ->
    % sort; (make hash come before range)
    lists:keysort(2, Acc).

% Determines which key conditions are hash or range based, and which are not.
% Returns a list of condition tuples where each tuple indicates if the
% condition is (by atom) hash|range|remaining.
map_key_conditions(Table, IndexName, KeyConditions, AWSContext) when is_binary(Table) ->
    [{table_keyschema, TableSchema},
     {lsi, LSI},
     {gsi, GSI}] = get_table_info(Table, AWSContext),
    % include LSI / GSI in the condition mapping
    % LSI we can combine with Table, since they share Hash Keys
    % GSI we have to separate.
    % Key Conditions may map against only one or the other.
    PrimaryKeySchema = TableSchema ++ collect_key_schema(LSI, []),
    GlobalKeySchema = collect_key_schema(lists:filter(
        fun(GS_Index) -> kvc:path(<<"IndexName">>, GS_Index) == IndexName
    end, GSI), []),
    case GlobalKeySchema of
        [] -> map_key_conditions(PrimaryKeySchema, KeyConditions, []);
        _ -> map_key_conditions(GlobalKeySchema, KeyConditions, [])
    end.
map_key_conditions([KeyPart|Rest], KeyConditions, Acc) ->
    {KeyAttr, KeyType} = KeyPart,
    case lists:keytake(KeyAttr, 1, KeyConditions) of
        {value, MatchedCondition, NewKeyConditions} ->
            map_key_conditions(Rest, NewKeyConditions, [{KeyType, MatchedCondition} | Acc]);
        false ->
            % key schema not in the conditions (error)
            map_key_conditions(Rest, KeyConditions, Acc)
    end;
map_key_conditions([], LeftoverConditions, Acc) ->
    lists:keysort(1, [{remaining, LeftoverConditions} | Acc]).

collect_key_schema([Index|Rest], Acc) ->
    KeySchema = map_key_types(kvc:path("KeySchema", Index), []),
    collect_key_schema(Rest, [KeySchema | Acc]);
collect_key_schema([], Acc) ->
    lists:flatten(lists:reverse(Acc)).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

hash_table_fixture() ->
    {_, Fixture} = file:read_file("../tests/fixtures/hash_table.json"),
    Fixture.

range_table_fixture() ->
    {_, Fixture} = file:read_file("../tests/fixtures/range_table.json"),
    Fixture.

item_fixture() ->
    {_, Fixture} = file:read_file("../tests/fixtures/item.json"),
    Fixture.

put_item_test() ->
    meck:new([rinamo_tables, rinamo_kv], [non_strict]),
    meck:expect(rinamo_tables, load_table_def, 2, jsx:decode(hash_table_fixture())),
    meck:expect(rinamo_kv, client, 0, ok),
    meck:expect(rinamo_kv, put, 5, ok),

    Table = <<"TableName">>,
    Item = kvc:path("Item", jsx:decode(item_fixture())),
    Expectations = [{}],
    AWSContext=#state{ owner_key = <<"TEST_API_KEY">> },
    _ = put_item(Table, Item, Expectations, AWSContext),

    meck:unload([rinamo_tables, rinamo_kv]).

get_item_test() ->
    TableFixture = jsx:decode(hash_table_fixture()),
    meck:new(rinamo_kv, [non_strict]),
    meck:expect(rinamo_tables, load_table_def, 2, jsx:decode(hash_table_fixture())),
    meck:expect(rinamo_kv, client, 0, ok),
    meck:expect(rinamo_kv, get, 3, {value, <<"[\"Some_Item_Def_JSON_Here\"]">>}),

    Table = <<"Item Table">>,
    Key = <<"Some_Item_Key">>,
    AWSContext=#state{ owner_key = <<"TEST_API_KEY">> },

    Actual = get_item(Table, Key, AWSContext),
    Expected = [<<"Some_Item_Def_JSON_Here">>],
    ?assertEqual(Expected, Actual),

    meck:unload([rinamo_tables, rinamo_kv]).

delete_item_test() ->
    meck:new(rinamo_kv, [non_strict]),
    meck:expect(rinamo_tables, load_table_def, 2, jsx:decode(hash_table_fixture())),
    meck:expect(rinamo_kv, client, 0, ok),
    meck:expect(rinamo_kv, delete, 3, {value, <<"[\"Some_Item_Def_JSON_Here\"]">>}),

    Table = <<"Item Table">>,
    Keys = [
        {<<"HASH">>, {<<"S">>, <<"Some_Item_Key">>}}
    ],
    AWSContext=#state{ owner_key = <<"TEST_API_KEY">> },

    Actual = delete_item(Table, Keys, AWSContext),
    Expected = ok,
    ?assertEqual(Expected, Actual),

    meck:unload([rinamo_tables, rinamo_kv]).

map_key_condition_range_test() ->
    meck:new([rinamo_tables, rinamo_kv], [non_strict]),
    meck:expect(rinamo_tables, load_table_def, 2, jsx:decode(range_table_fixture())),
    meck:expect(rinamo_kv, client, 0, ok),

    Table = <<"TableName">>,
    IndexName = [],
    KeyConditions = [
        {<<"Title">>,[{<<"S">>,<<"Some Title">>}],<<"EQ">>},
        {<<"ISBN">>, [{<<"N">>,<<"9876">>}],<<"GT">>},
        {<<"Id">>,[{<<"N">>,<<"101">>}],<<"EQ">>},
        {<<"AnotherCondition">>, [{<<"S">>,<<"XYZ">>}],<<"LT">>}],
    AWSContext=#state{ owner_key = <<"TEST_API_KEY">> },

    Actual = map_key_conditions(Table, IndexName, KeyConditions, AWSContext),

    Expected = [
     {hash,{<<"Id">>,[{<<"N">>,<<"101">>}],<<"EQ">>}},
     {range,{<<"Title">>,[{<<"S">>,<<"Some Title">>}],<<"EQ">>}},
     {remaining,[{<<"ISBN">>,[{<<"N">>,<<"9876">>}],<<"GT">>},
                 {<<"AnotherCondition">>,[{<<"S">>,<<"XYZ">>}],<<"LT">>}]}],

    ?assertEqual(Expected, Actual),

    meck:unload([rinamo_tables, rinamo_kv]).

query_one_one_test() ->
    meck:new([rinamo_config, rinamo_tables, rinamo_crdt_set], [non_strict]),
    meck:expect(rinamo_config, get_index_strategy, 0, rinamo_idx_one_for_one),
    meck:expect(rinamo_crdt_set, client, 0, ok),

    % mock out individual calls to rinamo_crdt_set
    SB_1 = [<<"Rinamo">>, ?RINAMO_SEPARATOR, <<"Index">>],
    SK_1 = ["TEST_API_KEY", ?RINAMO_SEPARATOR, "TableName", ?RINAMO_SEPARATOR,
            [], ?RINAMO_SEPARATOR, "Title", ?RINAMO_SEPARATOR, "102", ?RINAMO_SEPARATOR,
            "RefList"],
    ISB_1 = erlang:iolist_to_binary(SB_1),
    ISK_1 = erlang:iolist_to_binary(SK_1),

    SB_2 = ["TEST_API_KEY", ?RINAMO_SEPARATOR, "TableName", ?RINAMO_SEPARATOR,
            [], ?RINAMO_SEPARATOR, "Title"],
    SK_2 = ["102", ?RINAMO_SEPARATOR, "Book 102 Title"],
    ISB_2 = erlang:iolist_to_binary(SB_2),
    ISK_2 = erlang:iolist_to_binary(SK_2),

    meck:expect(rinamo_crdt_set, value, [
      {['_', ISB_1, ISK_1], {value, [<<"Book 102 Title">>]}},
      {['_', ISB_2, ISK_2], {value,
          [{<<"Book 102">>,
            [{<<"Id">>,[{<<"N">>,<<"102">>}]},
             {<<"Title">>,[{<<"S">>,<<"Book 102">>}]},
             {<<"ISBN">>,[{<<"S">>,<<"ABC">>}]}]}]
      }}
    ]),
    meck:expect(rinamo_tables, load_table_def, 2, jsx:decode(range_table_fixture())),

    Table = <<"TableName">>,
    KeyConditions = [
        {<<"Title">>,[{<<"S">>,<<"Book 102">>}],<<"BEGINS_WITH">>},
        {<<"ISBN">>, [{<<"S">>,<<"ABC">>}],<<"EQ">>},
        {<<"Id">>,[{<<"N">>,<<"102">>}],<<"EQ">>}],
    AWSContext=#state{ owner_key = <<"TEST_API_KEY">> },

    Actual = query(Table, <<>>, KeyConditions, AWSContext),

    Expected = [[
        {<<"Id">>,[{<<"N">>,<<"102">>}]},
        {<<"Title">>,[{<<"S">>,<<"Book 102">>}]},
        {<<"ISBN">>,[{<<"S">>,<<"ABC">>}]}
    ]],

    ?assertEqual(Expected, Actual),

    meck:unload([rinamo_config, rinamo_tables, rinamo_crdt_set]).

query_item_proxy_test() ->
    meck:new([rinamo_config, rinamo_tables, rinamo_crdt_set], [non_strict]),
    meck:expect(rinamo_config, get_index_strategy, 0, rinamo_idx_item_proxies),
    meck:expect(rinamo_crdt_set, client, 0, ok),
    meck:expect(rinamo_crdt_set, value, 3, {value,
        [{<<"Book 101">>,
         [{<<"Id">>,[{<<"N">>,<<"101">>}]},
          {<<"Title">>,[{<<"S">>,<<"Book 101">>}]},
          {<<"ISBN">>,[{<<"S">>,<<"ABC">>}]}]},
        {<<"Book 102">>,
         [{<<"Id">>,[{<<"N">>,<<"102">>}]},
          {<<"Title">>,[{<<"S">>,<<"Book 102">>}]},
          {<<"ISBN">>,[{<<"S">>,<<"XYZ">>}]}]}]
    }),
    meck:expect(rinamo_tables, load_table_def, 2, jsx:decode(range_table_fixture())),

    Table = <<"TableName">>,
    KeyConditions = [
        {<<"Title">>,[{<<"S">>,<<"Book 101">>}],<<"BEGINS_WITH">>},
        {<<"ISBN">>, [{<<"S">>,<<"ABC">>}],<<"EQ">>},
        {<<"Id">>,[{<<"N">>,<<"101">>}],<<"EQ">>}],
    AWSContext=#state{ owner_key = <<"TEST_API_KEY">> },

    Actual = query(Table, <<>>, KeyConditions, AWSContext),

    Expected = [[
        {<<"Id">>,[{<<"N">>,<<"101">>}]},
        {<<"Title">>,[{<<"S">>,<<"Book 101">>}]},
        {<<"ISBN">>,[{<<"S">>,<<"ABC">>}]}
    ]],

    ?assertEqual(Expected, Actual),

    meck:unload([rinamo_config, rinamo_tables, rinamo_crdt_set]).


-endif.
