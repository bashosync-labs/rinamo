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

-module(rinamo_error).

-include("rinamo.hrl").

-export([make/1, format/1]).

build_error(HttpCode, Code, Message) ->
    #error{http_code = HttpCode, code = Code, message = Message}.

make(access_denied) ->
    build_error(400,
        <<"AccessDeniedException">>,
        <<"Access denied.">>);

make(conditional_check_failed) ->
    build_error(400,
        <<"ConditionalCheckFailedException">>,
        <<"The conditional request failed.">>);

make(incomplete_signature) ->
    build_error(400,
        <<"IncompleteSignatureException">>,
        <<"The request signature does not conform to AWS standards.">>);

make(item_collection_size_limit_exceeded) ->
    build_error(400,
        <<"ItemCollectionSizeLimitExceededException">>,
        <<"Collection size exceeded.">>);

make(limit_exceeded) ->
    build_error(400,
        <<"LimitExceededException">>,
        <<"Too many operations for a given subscriber.">>);

make(missing_authentication_token) ->
    build_error(400,
        <<"MissingAuthenticationTokenException">>,
        <<"Request must contain a valid (registered) AWS Access Key ID.">>);

make(provisioned_throughput_exceeded) ->
    build_error(400,
        <<"ProvisionedThroughputExceededException">>,
        <<"You exceeded your maximum allowed provisioned throughput for a table or for one or more global secondary indexes. To view performance metrics for provisioned throughput vs. consumed throughput, go to the Amazon CloudWatch console.">>);

make(resource_in_use) ->
    build_error(400,
        <<"ResourceInUseException">>,
        <<"The resource which you are attempting to change is in use.">>);

make(resource_not_found) ->
    build_error(400,
        <<"ResourceNotFoundException">>,
        <<"The resource which is being requested does not exist.">>);

make(throttling) ->
    build_error(400,
        <<"ThrottlingException">>,
        <<"Rate of requests exceeds the allowed throughput.">>);

make(unrecognized_client) ->
    build_error(400,
        <<"UnrecognizedClientException">>,
        <<"The Access Key ID or security token is invalid.">>);

make(validation) ->
    build_error(400,
        <<"ValidationException">>,
        <<"One or more required parameter values were missing.">>);

make(request_too_large) ->
    build_error(413,
        <<"">>,
        <<"Request Entity Too Large.">>);

make(internal_failure) ->
    build_error(500,
        <<"InternalFailure">>,
        <<"The server encountered an internal error trying to fulfill the request.">>);

make(internal_server_error) ->
    build_error(500,
        <<"InternalServerError">>,
        <<"The server encountered an internal error trying to fulfill the request.">>);

make(service_unavailable) ->
    build_error(500,
        <<"ServiceUnavailableException">>,
        <<"The service is currently unavailable or busy.">>);

% Observed AWS Errors that are outside of their documentation

make(table_exists) ->
    build_error(400,
        <<"ResourceInUseException">>,
        <<"Cannot create preexisting table.">>);

make(table_missing) ->
    build_error(400,
        <<"ResourceNotFoundException">>,
        <<"Cannot do operations on a non-existent table.">>);

make(validation_hash_condition) ->
    build_error(400,
        <<"ValidationException">>,
        <<"All queries must have a condition on the hash key, and it must be of type EQ.">>);

make(validation_range_condition) ->
    build_error(400,
        <<"ValidationException">>,
        <<"Range Condition does not match range key">>);

make(validation_comparison_type) ->
    build_error(400,
        <<"ValidationException">>,
        <<"Comparison type not valid for query">>);

make(return_values_invalid) ->
    build_error(400,
        <<"ValidationException">>,
        <<"Return values set to invalid value">>);

make(lsi_same_hashkey) ->
    build_error(400,
        <<"ValidationException">>,
        <<"Local Secondary indices must have the same hash key as the main table">>);

make(too_many_conditions) ->
    build_error(400,
        <<"ValidationException">>,
        <<"There are too many conditions in this query">>);

% Basho Specific Errors

make(missing_operation_target) ->
    build_error(400,
        <<"OperationNotPermittedException">>,
        <<"Request must contain a valid AWS Dynamo Operation.">>);

make(operation_not_implemented) ->
    build_error(500,
        <<"InternalServerErrorException">>,
        <<"Operation Not Implemented.">>);

make(insufficient_vnodes_available) ->
    build_error(500,
        <<"InternalServerErrorException">>,
        <<"Insufficient VNodes Available.">>);

make(validation_operand_count) ->
    build_error(400,
        <<"ValidationException">>,
        <<"Invalid Operand Count">>).

format(Error) ->
    [{<<"__type">>, Error#error.code},
     {<<"Message">>, Error#error.message}].
