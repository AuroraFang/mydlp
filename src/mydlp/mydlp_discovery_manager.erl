%%%
%%%    Copyright (C) 2010 Ozgen Muzac <ozgen@mydlp.com>
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
%%% @author Ozgen Muzac <ozgen@mydlp.com>
%%% @copyright 2013, Ozgen Muzac
%%% @doc Worker for mydlp.
%%% @end
%%%-------------------------------------------------------------------

-module(mydlp_discovery_manager).
-author("ozgen@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_schema.hrl").


%% API
-export([start_link/0,
	stop/0,
	start_on_demand_discovery/1,
	stop_discovery_on_demand/1,
	pause_discovery_on_demand/1,
	get_report_id/1,
	start_discovery/1,
	stop_discovery/1,
	pause_discovery/1,
	start_at_exact_hour/0,
	start_discovery_scheduling/0
	]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {
	discovery_dict,
	timer_dict
}).

-define(DISC, discovering).
-define(ON_DEMAND_DISC, on_demand_discovering).
-define(SYSTEM_PAUSED, system_paused).
-define(USER_PAUSED, user_paused).
-define(SYSTEM_STOPPED, system_stopped).
-define(USER_STOPPED, user_stopped).
-define(FINISHED, finished).
-define(REMOTE_DISCOVERY, mydlp_discover_rfs).
-define(EP_DISCOVERY, hede).
-define(TRY_COUNT, 5).

%%%%%%%%%%%%%  API

start_on_demand_discovery(RuleOrigId) ->
	RuleId = mydlp_mnesia:get_rule_id_by_orig_id(RuleOrigId),
	gen_server:cast(?MODULE, {start_on_demand, RuleId}),
	ok.

stop_discovery_on_demand(RuleOrigId) ->
	RuleId = mydlp_mnesia:get_rule_id_by_orig_id(RuleOrigId),
	gen_server:cast(?MODULE, {stop_on_demand, RuleId}),
	ok.

pause_discovery_on_demand(RuleOrigId) ->
	RuleId = mydlp_mnesia:get_rule_id_by_orig_id(RuleOrigId),
	gen_server:cast(?MODULE, {pause_on_demand, RuleId}),
	ok.

get_report_id(RuleId) -> gen_server:call(?MODULE, {get_report_id, RuleId}).

%%%%%%%%%%%%%% gen_server handles

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call({get_report_id, RuleId}, _From, #state{discovery_dict=Dict}=State) ->
	Reply = case dict:find(RuleId, Dict) of
			{ok, {_, ReportId}} -> ReportId;
			_ -> -1
		end,
	{reply, Reply, State};

handle_call({is_paused_or_stopped, RuleId}, _From, #state{discovery_dict=Dict}=State) ->
	Reply = case dict:find(RuleId, Dict) of
			{ok, {?SYSTEM_PAUSED, _}} -> paused;
			{ok, {?USER_PAUSED, _}} -> paused;
			{ok, {?SYSTEM_STOPPED, _}} -> stopped;
			{ok, {?USER_STOPPED, _}} -> stopped;
			_ -> none
		end,
	{reply, Reply, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.


handle_cast({start_on_demand, RuleId}, #state{discovery_dict=Dict, timer_dict=TimerDict}=State) ->
	erlang:display({bs, dict:to_list(Dict)}),
	TimerDict2 = create_timer(RuleId, TimerDict),
	Dict2 = call_start_discovery_on_target(RuleId, Dict, true),
	erlang:display({as, dict:to_list(Dict2)}),
	{noreply, State#state{discovery_dict=Dict2, timer_dict=TimerDict2}};

handle_cast({pause_on_demand, RuleId}, #state{discovery_dict=Dict}=State) ->
	erlang:display({bp, dict:to_list(Dict)}),
	Dict2 = call_pause_discovery_on_target(RuleId, Dict, true),
	erlang:display({ap, dict:to_list(Dict2)}),
	{noreply, State#state{discovery_dict=Dict2}};

handle_cast({stop_on_demand, RuleId}, #state{discovery_dict=Dict}=State) ->
	erlang:display({bst, dict:to_list(Dict)}),
	Dict2 = call_stop_discovery_on_target(RuleId, Dict, true),
	erlang:display({ast, dict:to_list(Dict2)}),
	{noreply, State#state{discovery_dict=Dict2}};

handle_cast({manage_schedules, Schedules}, #state{discovery_dict=Dict}=State) ->
	erlang:display({manage_schedules, Schedules}),
	edit_dictionary(Schedules, Dict),
	{noreply, State};

handle_cast({start_discovery, RuleId}, #state{discovery_dict=Dict, timer_dict=TimerDict}=State) ->
	erlang:display({bs1, dict:to_list(Dict)}),
	TimerDict2 = create_timer(RuleId, TimerDict),
	Dict2 = call_start_discovery_on_target(RuleId, Dict, false),
	erlang:display({as1, dict:to_list(Dict2)}),
	{noreply, State#state{discovery_dict=Dict2, timer_dict=TimerDict2}};

handle_cast({stop_discovery, RuleId}, #state{discovery_dict=Dict}=State) ->
	erlang:display({bst1, dict:to_list(Dict)}),
	Dict2 = call_stop_discovery_on_target(RuleId, Dict, false),
	erlang:display({ast1, dict:to_list(Dict2)}),
	{noreply, State#state{discovery_dict=Dict2}};

handle_cast({pause_discovery, RuleId}, #state{discovery_dict=Dict}=State) ->
	erlang:display({bp, dict:to_list(Dict)}),
	Dict2 = call_pause_discovery_on_target(RuleId, Dict, false),
	erlang:display({ap, dict:to_list(Dict2)}),
	{noreply, State#state{discovery_dict=Dict2}};

handle_cast({continue_discovery, RuleId}, #state{discovery_dict=Dict}=State) ->
	Dict2 = call_continue_discovery_on_target(RuleId, Dict),
	{noreply, State#state{discovery_dict=Dict2}};

handle_cast({cancel_timer, RuleId}, #state{timer_dict=TimerDict}=State) ->
	case dict:find(RuleId, TimerDict) of
		{ok, TRef} -> (catch timer:cancel_timer(TRef));
		_ -> ok
	end,
	TimerDict1 = dict:erase(RuleId, TimerDict),
	{noreply, State#state{timer_dict=TimerDict1}};

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(startup, State) ->
	start_at_exact_hour(),
	{noreply, State};

handle_info(start_discovery_scheduling, State) ->
	start_discovery_scheduling(),
	{noreply, State};

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info({is_discovery_finished, RuleId}, #state{discovery_dict=DiscDict, timer_dict=TimerDict}=State) ->
	erlang:display("TIMER IS ELAPSED"),
	erlang:display(dict:to_list(TimerDict)),
	case dict:find(RuleId, TimerDict) of
		error -> {noreply, State#state{discovery_dict=DiscDict, timer_dict=TimerDict}};
		{ok, Timer} ->
			try
			cancel_timer(Timer),
			Reply = mydlp_discover_fs:is_discovery_finished(RuleId),
			erlang:display({is_finished_resp, Reply}),
			case Reply of
				true ->	 
					TimerDict1 = dict:erase(RuleId, TimerDict),
					{ok, {_, ReportId}} = dict:find(RuleId, DiscDict),
					mydlp_discover_rfs:release_mount_by_rule_id(RuleId),
					generate_discovery_report(ReportId),
					DiscDict1 = dict:store(RuleId,{?FINISHED, ReportId}, DiscDict),
					{noreply, State#state{discovery_dict=DiscDict1, timer_dict=TimerDict1}};
				false -> 
					Timer1 = timer:send_after(60000, {is_discovery_finished, RuleId}),
					TimerDict1 = dict:store(RuleId, Timer1, TimerDict),
					{noreply, State#state{discovery_dict=DiscDict, timer_dict=TimerDict1}}
			end
			catch _Class:_Error ->
				erlang:display("SOME EXCEPTION IS OCCURED"),
				Timer2 = timer:send_after(60000, {is_discovery_finished, RuleId}),
				TimerDict2 = dict:store(RuleId, Timer2, TimerDict),
				{noreply, State#state{discovery_dict=DiscDict, timer_dict=TimerDict2}}
			end
	end;

handle_info(_Info, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%% Implicit functions


start_link() ->
	case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
		{ok, Pid} -> {ok, Pid};
		{error, {already_started, Pid}} -> {ok, Pid}
	end.

stop() ->
	gen_server:call(?MODULE, stop).

init([]) ->
	timer:send_after(6000, startup),
	{ok, #state{discovery_dict=dict:new(), timer_dict=dict:new()}}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%%%%%%% internal

start_discovery(RuleId) -> gen_server:cast(?MODULE, {start_discovery, RuleId}).

stop_discovery(RuleId) -> gen_server:cast(?MODULE, {stop_discovery, RuleId}).

pause_discovery(RuleId) -> gen_server:cast(?MODULE, {pause_discovery, RuleId}).

continue_discovery(RuleId) -> gen_server:cast(?MODULE, {continue_discovery, RuleId}).

call_start_discovery_on_target(RuleId, Dict, IsOnDemand) ->
	case mydlp_mnesia:get_rule_channel(RuleId) of
		remote_discovery -> call_remote_storage_discovery(RuleId, Dict, IsOnDemand);
		discovery -> call_ep_discovery(RuleId);
		C -> ?ERROR_LOG("Unknown Rule Type: "?S"", [C]), 
			Dict
	end.

call_remote_storage_discovery(RuleId, Dict, IsOnDemand) -> 
	Resp = get_discovery_status(RuleId, Dict),
	erlang:display({status, Resp}),
	case Resp of
		{disc, ReportId} -> 
			case IsOnDemand of 
				false -> Dict;
				true -> break_discovery(RuleId, ReportId, Dict)
			end;
		{paused, ReportId} -> gen_server:cast(?REMOTE_DISCOVERY, {continue_discovering}),
			case IsOnDemand of
				true -> dict:store(RuleId, {?ON_DEMAND_DISC, ReportId}, Dict);
				false -> break_discovery(RuleId, ReportId, Dict) % This case looks like impossible
			end;
		{user_paused, ReportId} ->
			case IsOnDemand of
				true -> % means that user paused discovery while ago and now starts again
					erlang:display("Come on start discovery again now."),
					gen_server:cast(?REMOTE_DISCOVERY, {continue_discovering}),
					dict:store(RuleId, {?ON_DEMAND_DISC, ReportId}, Dict);
				false ->% means that user paused discovery while ago and now it is time to schedule
					% New discovery with a new report id. Ensure that last discovery is stopped.
					mydlp_mnesia:del_fs_entries_by_rule_id(RuleId),
					break_discovery(RuleId, ReportId, Dict)
			end; 
		_ -> RId = generate_report_id(RuleId), % Discovering should be start with new Report id.
			gen_server:cast(?REMOTE_DISCOVERY, {start_by_rule_id, RuleId, RId}),
			case IsOnDemand of
				true -> dict:store(RuleId, {?ON_DEMAND_DISC, RId}, Dict);
				false -> dict:store(RuleId, {?DISC, RId}, Dict)
			end
	end.

call_ep_discovery(_RuleId) -> ok.

call_pause_discovery_on_target(RuleId, Dict, IsOnDemand) -> 
	case mydlp_mnesia:get_rule_channel(RuleId) of
		remote_discovery -> set_pause_remote_storage_discovery(RuleId, Dict, IsOnDemand);
		discovery -> call_pause_ep_discovery(RuleId);
		C -> ?ERROR_LOG("Unknown Rule Type: "?S"", [C])
	end.

set_pause_remote_storage_discovery(RuleId, Dict, IsOnDemand) ->
	case get_discovery_status(RuleId, Dict) of
		{disc, ReportId} -> 
			cancel_timer(RuleId),
			case IsOnDemand of 
				true -> dict:store(RuleId, {?USER_PAUSED, ReportId}, Dict);
				false -> dict:store(RuleId, {?SYSTEM_PAUSED, ReportId}, Dict) end;
		{user_disc, ReportId} -> 
			case IsOnDemand of
				true -> cancel_timer(RuleId),
					dict:store(RuleId, {?USER_PAUSED, ReportId}, Dict);
				false -> Dict
			end;
		_ -> Dict
	end.

call_pause_ep_discovery(_RuleId) -> ok.
	
call_stop_discovery_on_target(RuleId, Dict, IsOnDemand) ->
	case mydlp_mnesia:get_rule_channel(RuleId) of
		remote_discovery -> set_stop_remote_storage_discovery(RuleId, Dict, IsOnDemand);
		discovery -> call_stop_ep_discovery(RuleId);
		C -> ?ERROR_LOG("Unknown Rule Type: "?S"", [C])
	end. 

set_stop_remote_storage_discovery(RuleId, Dict, IsOnDemand) ->
	mydlp_mnesia:del_fs_entries_by_rule_id(RuleId),
	case get_discovery_status(RuleId, Dict) of
		none -> Dict;
		stop -> Dict;
		{_, ReportId} -> % discovering or paused
			generate_discovery_report(ReportId),
			cancel_timer(RuleId),
			mydlp_discover_rfs:release_mount_by_rule_id(RuleId),
			case IsOnDemand of
				true -> dict:store(RuleId, {?USER_STOPPED, ReportId}, Dict);
				false -> dict:store(RuleId, {?SYSTEM_STOPPED, ReportId}, Dict) end
	end.

call_stop_ep_discovery(_RuleId) -> ok.

call_continue_discovery_on_target(RuleId, Dict) ->
	case mydlp_mnesia:get_rule_channel(RuleId) of
		remote_discovery -> call_continue_remote_storage_discovery(RuleId, Dict);
		discovery -> call_continue_ep_discovery(RuleId);
		C -> ?ERROR_LOG("Unknown Rule Type: "?S"", [C])
	end.

call_continue_remote_storage_discovery(RuleId, Dict) ->
	case get_discovery_status(RuleId, Dict) of
		{paused, ReportId} -> gen_server:cast(?REMOTE_DISCOVERY, {continue_discovering}),
					dict:store(RuleId, {?DISC, ReportId}, Dict);
		_ -> Dict
	end.

call_continue_ep_discovery(_RuleId) -> ok.	

generate_discovery_report(_ReportId) -> ok.

generate_report_id(RuleId) ->
	integer_to_list(RuleId) ++ "_" ++ integer_to_list(calendar:datetime_to_gregorian_seconds(erlang:localtime())).

cancel_timer(RuleId) -> gen_server:cast(?MODULE, {cancel_timer, RuleId}).

create_timer(RuleId, TimerDict) ->
	case dict:find(RuleId, TimerDict) of
		{ok, TRef} -> timer:cancel(TRef);
		_ -> ok
	end,

	Timer = timer:send_after(60000, {is_discovery_finished, RuleId}),
	dict:store(RuleId, Timer, TimerDict).

break_discovery(RuleId, ReportId, Dict) ->
	case gen_server:call(?REMOTE_DISCOVERY, {stop_discovery, RuleId}) of
		ok -> generate_discovery_report(ReportId),
			ReportId1 = generate_report_id(RuleId),
			gen_server:cast(?REMOTE_DISCOVERY, {start_by_rule_id, RuleId, ReportId1}),
			dict:store(RuleId, {?DISC, ReportId1}, Dict);
		R -> ?OPR_LOG("Failed to scheduling discovery: "?S"", [R]), 
			Dict
	end.

get_discovery_status(RuleId, Dict) ->
	case dict:find(RuleId, Dict) of
		{ok, {?DISC, ReportId}} -> {disc, ReportId};
		{ok, {?ON_DEMAND_DISC, ReportId}} -> {user_disc, ReportId};
		{ok, {?SYSTEM_PAUSED, ReportId}} -> {paused, ReportId};
		{ok, {?USER_PAUSED, ReportId}} -> {user_paused, ReportId};
		{ok, _} -> stop;
		_ -> none
	end.

edit_dictionary([RuleId|Rest], Dict) ->
	case mydlp_mnesia:get_availabilty_by_rule_id(RuleId) of
		true -> start_discovery(RuleId); 
		false -> ok
	end,
	edit_dictionary(Rest, Dict);
edit_dictionary(none, Dict) -> control_already_scheduled_discoveries(Dict);
edit_dictionary([], Dict) -> control_already_scheduled_discoveries(Dict).

control_already_scheduled_discoveries(Dict) ->
	DiscoveryList = dict:to_list(Dict),
	edit_discoveries(DiscoveryList).

edit_discoveries([{RuleId, {?SYSTEM_PAUSED, _}}|R]) ->
	case mydlp_mnesia:get_availabilty_by_rule_id(RuleId) of
		true -> continue_discovery(RuleId);
		false -> ok
	end,
	edit_discoveries(R);
edit_discoveries([{RuleId, {?DISC, _}}|R]) ->
	case mydlp_mnesia:get_availabilty_by_rule_id(RuleId) of
		true -> ok;
		false -> pause_discovery(RuleId)
	end,
	edit_discoveries(R);
edit_discoveries([_|R]) -> edit_discoveries(R);
edit_discoveries([]) -> ok.

start_at_exact_hour() -> % Remaining should be multiplied with 1000
	{_D, {_H, M, S}} = erlang:localtime(),
	erlang:display({exactHour, M, S}),
	case M of 
		0 -> timer:send_after(0, start_discovery_scheduling);
		_ -> Remaining = (((59-M)*60)+S),
			timer:send_after(Remaining, start_discovery_scheduling)
	end.

start_discovery_scheduling() ->
	{_D, {H, _M, _S}} = erlang:localtime(),
	Schedules = mydlp_mnesia:get_schedules_by_hour(H),
	gen_server:cast(?MODULE, {manage_schedules, Schedules}),
	timer:send_after(600000, start_discovery_scheduling).
