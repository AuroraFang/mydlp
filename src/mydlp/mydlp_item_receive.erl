%%%
%%%    Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@mydlp.com>
%%%
%%%--------------------------------------------------------------------------
%%%    This file is part of MyDLP.
%%%
%%%    MyDLP is free software: you can redistribute it and/or modify
%%%    it under the terms of the GNU General Public License as published by
%%%    the Free Software Foundation, either version 3 of the License, or
%%%    (at your option) any later version.
%%%
%%%    MyDLP is distributed in the hope that it will be useful,
%%%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%    GNU General Public License for more details.
%%%
%%%    You should have received a copy of the GNU General Public License
%%%    along with MyDLP.  If not, see <http://www.gnu.org/licenses/>.
%%%--------------------------------------------------------------------------

%%%-------------------------------------------------------------------
%%% @author H. Kerem Cevahir <kerem@mydlp.com>
%%% @copyright 2011, H. Kerem Cevahir
%%% @doc Worker for mydlp.
%%% @end
%%%-------------------------------------------------------------------

-ifdef(__MYDLP_NETWORK).

-module(mydlp_item_receive).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").

%% API
-export([start_link/0,
	r/2,
	process_item/1,
	stop/0]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {
	item_queue,
	item_inprog = false
}).

%%%%%%%%%%%%%  API

r(EndpointId, Item) -> gen_server:cast(?MODULE, {r, EndpointId, Item}).

%%%%%%%%%%%%%% gen_server handles

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_cast({r, EndpointId, Bin}, State) when is_binary(Bin) ->
	try	Term = erlang:binary_to_term(Bin),
		handle_cast({r, EndpointId, Term}, State)
	catch Class:Error ->
		?ERROR_LOG("ITEM_RECEIVE: Error occured: Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~nEndpointId: ["?S"] Bin: "?S".~nState: "?S"~n ",
			[Class, Error, erlang:get_stacktrace(), EndpointId, Bin, State]),
		{noreply, State}
	end;

handle_cast({r, EndpointId, Item}, #state{item_queue=Q, item_inprog=false} = State) ->
	Q1 = queue:in({EndpointId, Item}, Q),
	consume_item(),
	{noreply, State#state{item_queue=Q1, item_inprog=true}};

handle_cast({r, EndpointId, Item}, #state{item_queue=Q, item_inprog=true} = State) ->
	Q1 = queue:in({EndpointId, Item}, Q),
	{noreply,State#state{item_queue=Q1}};

handle_cast(consume_item, #state{item_queue=Q} = State) ->
	case queue:out(Q) of
		{{value, ItemTuple}, Q1} ->
			process_item(ItemTuple),
			consume_item(),
			{noreply, State#state{item_queue=Q1}};
		{empty, _} ->
			{noreply, State#state{item_inprog=false}}
	end;

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info(_Info, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%% Implicit functions

consume_item() -> gen_server:cast(?MODULE, consume_item).

start_link() ->
	case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
		{ok, Pid} -> {ok, Pid};
		{error, {already_started, Pid}} -> {ok, Pid}
	end.

stop() ->
	gen_server:call(?MODULE, stop).

init([]) ->
	{ok, #state{item_queue=queue:new()}}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%%%%%%% internal

process_item({_EndpointId, []}) -> ok;
process_item({EndpointId, [Item|Rest]}) -> 
	process_item({EndpointId, Item}),
	process_item({EndpointId, Rest});
process_item({EndpointId, {endpoint_log, LogTerm} }) -> 
	{IpAddress, _UserH, _Hostname} = mydlp_mnesia:get_user_from_endpoint_id(EndpointId),
	case LogTerm of
		#log{file=Files} ->
			Files1 = [ mydlp_api:reconstruct_cr(F) || F <- Files ], % To clean invalid cachrefs
			?ACL_LOG(LogTerm#log{ip=IpAddress, file=Files1});
		{log, Time, Channel, RuleId, Action, Ip, User, Destination, ITypeId, Files, Misc, Payload} -> % for 2.0.7 compatibility
			LogTerm1 = #log{time=Time, channel=Channel, rule_id=RuleId, action=Action, 
					user=User, ip=Ip, destination=Destination, itype_id=ITypeId,
					file=Files, misc=Misc, payload=Payload},
			process_item({EndpointId, {endpoint_log, LogTerm1}});
		_Else -> ?ERROR_LOG("RECEIVE: Unexpected enpdoint_log item: ?S", [LogTerm]) end;
process_item({EndpointId, {endpoint_opr_log, Context, #opr_log{} = Term}}) -> 
	{IpAddress, _UserH, _Hostname} = mydlp_mnesia:get_user_from_endpoint_id(EndpointId),
	mydlp_mysql:push_opr_log(Context, {ep_opr_log, Term#opr_log{ip_address=IpAddress, endpoint_id=EndpointId}});
process_item(Item) -> 
	?ERROR_LOG("RECEIVE: Unexpected item: ?S", [Item]),
	ok. % TODO log unkown item.

-endif.

