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

-module(rinamo_handler_root).
-behaviour(cowboy_http_handler).

-export([
    init/3,
    handle/2,
    terminate/3
]).

-include("rinamo.hrl").

init(_Type, Req, _Opts) ->
    {ok, Req, _Opts}.

handle(Req, State) ->
    {AmzOp, _} = cowboy_req:header(?AMZ_OP_HEADER, Req),

    {_, TaggedReq} = case AmzOp of
      undefined ->
          ErrorMsg = rinamo_error:make(missing_operation_target),
          rinamo_response:send(ErrorMsg#error.http_code, rinamo_error:format(ErrorMsg), Req);
      _ ->
          {AWS_Op, _} = extract_operation(binary_to_list(AmzOp)),
          lager:debug("AWS Operation: ~p~n", [AmzOp]),

          OpFun = case AWS_Op of
              <<"CreateTable">> -> {rinamo_api, create_table};
              <<"UpdateTable">> -> {error, unimplemented};
              <<"DeleteTable">> -> {rinamo_api, delete_table};
              <<"ListTables">> -> {rinamo_api, list_tables};
              <<"DescribeTable">> -> {rinamo_api, describe_table};
              <<"GetItem">> -> {rinamo_api, get_item};
              <<"PutItem">> -> {rinamo_api, put_item};
              <<"UpdateItem">> -> {error, unimplemented};
              <<"DeleteItem">> -> {rinamo_api, delete_item};
              <<"Query">> -> {rinamo_api, query};
              <<"Scan">> -> {error, unimplemented};
              <<"BatchGetItem">> -> {error, unimplemented};
              <<"BatchWriteItem">> -> {error, unimplemented};
          _ -> {error, unimplemented}
        end,

        lager:debug("OpFun: ~p~n", [OpFun]),

        Body = State#state.body,

        case OpFun of
            {error, unimplemented} ->
                ErrorMsg = rinamo_error:make(operation_not_implemented),
                rinamo_response:send(ErrorMsg#error.http_code, rinamo_error:format(ErrorMsg), Req);
            {Module, Function} ->
                Result = (catch erlang:apply(Module, Function, [jsx:decode(Body), State])),
                lager:debug("Operation Result: ~p~n", [Result]),
                case Result of
                    {'EXIT', Reason} -> % unanticipated errors
                        lager:error("General Protection Fault: ~p~n", [Reason]),
                        ErrorMsg = rinamo_error:make(internal_server_error),
                        rinamo_response:send(ErrorMsg#error.http_code, rinamo_error:format(ErrorMsg), Req);
                    _ when is_atom(Result) -> % anticipated errors
                        ErrorMsg = rinamo_error:make(Result),
                        rinamo_response:send(ErrorMsg#error.http_code, rinamo_error:format(ErrorMsg), Req);
                    _ -> % normal response
                        rinamo_response:send(200, Result, Req)
                end
        end

    end,

    {ok, TaggedReq, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%% Internal
extract_operation(OpHeader) ->
    case OpHeader of
        undefined -> {undefined, undefined};
        _ ->
            case string:chr(OpHeader, $.) of
                0 -> {OpHeader, undefined};
                Pos -> {
                    list_to_binary(string:substr(OpHeader, Pos+1)),
                    list_to_binary(string:substr(OpHeader, 1, Pos-1))}
            end
    end.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

extract_operation_test() ->
    TargetHeader = "DynamoDB_20120810.ListTables",
    Actual = extract_operation(TargetHeader),
    Expected = {<<"ListTables">>, <<"DynamoDB_20120810">>},
    ?assertEqual(Expected, Actual),
    ?assertEqual({undefined, undefined}, extract_operation(undefined)).

-endif.
