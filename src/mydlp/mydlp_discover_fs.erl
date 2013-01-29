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


-ifdef(__MYDLP_ENDPOINT).

-module(mydlp_discover_fs).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_schema.hrl").

-include_lib("kernel/include/file.hrl").

%% API
-export([start_link/0,
	q/2,
	q/3,
	stop_discovery/0,
	schedule_discovery/0,
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
	discover_queue,
	discover_inprog=false,
	timer
}).


is_substring(_FileName, []) -> false;
is_substring(FileName, [Head|Tail]) ->
	case string:str(FileName, Head) of
		1 -> true;
		_ -> is_substring(FileName, Tail)
	end.

-ifdef(__PLATFORM_WINDOWS).

-define(EXCEPTIONS_FILE, [
	"ntuser.dat"
]).

-define(EXCEPTIONS_DIR, [
	"appdata"
]).

	
is_exceptional(FilePath) ->
	FileName = filename:basename(FilePath, ""),
	FileName1 = string:to_lower(FileName),
	case filelib:is_regular(FilePath) of
		true -> is_substring(FileName1, ?EXCEPTIONS_FILE);
		false -> is_substring(FileName1, ?EXCEPTIONS_DIR)
	end.

-endif.

-ifdef(__PLATFORM_LINUX).

is_exceptional(FilePath) -> false.

-endif.

%%%%%%%%%%%%%  API

q(FilePath, RuleIndex) -> q(none, FilePath, RuleIndex).

q(ParentId, FilePath, RuleIndex) -> gen_server:cast(?MODULE, {q, ParentId, FilePath, RuleIndex}).

stop_discovery() -> gen_server:cast(?MODULE, stop_discovery).

schedule_discovery() -> gen_server:cast(?MODULE, schedule_discovery).

%%%%%%%%%%%%%% gen_server handles

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_cast({q, ParentId, FilePath, RuleIndex}, #state{discover_queue=Q, discover_inprog=false} = State) ->
	Q1 = queue:in({ParentId, FilePath, RuleIndex}, Q),
	consume(),
	set_discover_inprog(),
	{noreply, State#state{discover_queue=Q1, discover_inprog=true}};

handle_cast({q, ParentId, FilePath, RuleIndex}, #state{discover_queue=Q, discover_inprog=true} = State) ->
	Q1 = queue:in({ParentId, FilePath, RuleIndex}, Q),
	{noreply,State#state{discover_queue=Q1}};

handle_cast(consume, #state{discover_queue=Q} = State) ->
	case queue:out(Q) of
		{{value, {ParentId, FilePath, RuleIndex}}, Q1} ->
			try	case has_discover_rule() of
					true -> case is_exceptional(FilePath) of
							false -> discover(ParentId, FilePath, RuleIndex);
							true -> ok end;
					false -> ok end,
				consume(),
				{noreply, State#state{discover_queue=Q1}}
			catch Class:Error ->
				?ERROR_LOG("Discover Queue Consume: Error occured: "
						"Class: ["?S"]. Error: ["?S"].~n"
						"Stack trace: "?S"~n.FilePath: "?S"~nState: "?S"~n ",	
						[Class, Error, erlang:get_stacktrace(), FilePath, State]),
					consume(),
					{noreply, State#state{discover_queue=Q1}} end;
		{empty, _} ->
			State1 = schedule_timer(State, ?CFG(discover_fs_interval)),
			unset_discover_inprog(),
			{noreply, State1#state{discover_inprog=false}}
	end;

handle_cast(stop_discovery, State) ->
	NewQ = queue:new(),
	{noreply, State#state{discover_queue=NewQ}};

handle_cast(schedule_discovery, State) -> handle_info(schedule_now, State);

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(schedule_now, State) ->
	State1 = cancel_timer(State),
	schedule(),
	{noreply, State1};

handle_info(schedule_startup, State) ->
	State1 = case ?CFG(discover_fs_on_startup) of
		true -> schedule(), State;
		false -> schedule_timer(State, ?CFG(discover_fs_interval)) end,
	{noreply, State1};

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info(_Info, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%% Implicit functions

has_discover_rule() ->
	case mydlp_mnesia:get_rule_table(discovery) of
		none -> false;
		{_ACLOpts, {_Id, pass}, []} -> false;
		_Else -> true end.

cancel_timer(#state{timer=Timer} = State) ->
	case Timer of
		undefined -> ok;
		TRef ->	(catch timer:cancel(TRef)) end,
	State#state{timer=undefined}.
	
schedule_timer(State, Interval) ->
	State1 = cancel_timer(State),
	Timer = case timer:send_after(Interval, schedule_now) of
		{ok, TRef} -> TRef;
		{error, _} = Error -> ?ERROR_LOG("Can not create timer. Reason: "?S, [Error]), undefined end,
	State1#state{timer=Timer}.

schedule() ->
	PathsWithRuleIndex = mydlp_mnesia:get_discovery_directory(), % {Path, IndexInWhichRuleHasThisPath}
	PathList = case PathsWithRuleIndex of
		none -> [];
		L when is_list(L) ->
			lists:map(fun({P, Index}) -> 
				{try unicode:characters_to_list(P)
					catch _:_ -> binary_to_list(P) end,  %% TODO: log this case
				Index} end
			, L) end,	
	lists:foreach(fun({P, I}) -> q(P, I) end, PathList),
	ok.

consume() -> gen_server:cast(?MODULE, consume).

start_link() ->
	case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
		{ok, Pid} -> {ok, Pid};
		{error, {already_started, Pid}} -> {ok, Pid}
	end.

stop() ->
	gen_server:call(?MODULE, stop).

init([]) ->
	timer:send_after(60000, schedule_startup),
	{ok, #state{discover_queue=queue:new()}}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%%%%%%% internal

meta(FilePath) ->
	{ok, FileInfo} = file:read_file_info(FilePath),
	{FileInfo#file_info.mtime, FileInfo#file_info.size}.

is_changed(#fs_entry{file_id={FP, _RuleIndex}, file_size=FSize, last_modified=LMod} = E) ->
	{MTime, CSize} = meta(FP),
	case ( (LMod /= MTime) or (CSize /= FSize) ) of
		true -> mydlp_mnesia:add_fs_entry(E#fs_entry{file_size=CSize, last_modified=MTime}), % update mnesia entry
			true;
		false -> false end.

fs_entry(ParentId, FilePath, RuleIndex) ->
	FileId = {FilePath, RuleIndex},
	case mydlp_mnesia:get_fs_entry(FileId) of
		none -> Id = mydlp_mnesia:get_unique_id(fs_entry),
			E = #fs_entry{file_id=FileId, entry_id=Id, parent_id=ParentId},
			mydlp_mnesia:add_fs_entry(E), %% bulk write may improve performance
			E;
		#fs_entry{} = FS -> FS end.

discover_file(#fs_entry{file_id={FP, RuleIndex}}) ->
	try	timer:sleep(20),
		{ok, ObjId} = mydlp_container:new(),
		ok = mydlp_container:setprop(ObjId, "channel", "discovery"),
		ok = mydlp_container:setprop(ObjId, "rule_index", RuleIndex),
		ok = mydlp_container:pushfile(ObjId, {raw, FP}),
		ok = mydlp_container:eof(ObjId),
		{ok, Action} = mydlp_container:aclq(ObjId),
		ok = mydlp_container:destroy(ObjId),
		case Action of
			block -> ok = file:delete(FP);
			pass -> ok end
	catch Class:Error ->
		?ERROR_LOG("DISCOVER FILE: Error occured: Class: ["?S"]. Error: ["?S"].~n"
				"Stack trace: "?S"~nFilePath: ["?S"].~n",
			[Class, Error, erlang:get_stacktrace(), FP])
	end,
	ok.

discover_dir(#fs_entry{file_id={FP, RuleIndex}, entry_id=EId}) ->
	CList = case file:list_dir(FP) of
		{ok, LD} -> LD;
		{error, _} -> [] end,
	OList = mydlp_mnesia:fs_entry_list_dir(EId),
	MList = lists:umerge([CList, OList]),
	[ q(EId, filename:absname(FN, FP), RuleIndex) || FN <- MList ],
	ok.

discover_dir_dir(#fs_entry{file_id={FP, RuleIndex}, entry_id=EId}) ->
	OList = mydlp_mnesia:fs_entry_list_dir(EId),
	[ q(EId, filename:absname(FN, FP), RuleIndex) || FN <- OList ],
	ok.

discover(ParentId, FilePath, RuleIndex) ->
	case filelib:is_regular(FilePath) of
		true -> E = fs_entry(ParentId, FilePath, RuleIndex),
			case is_changed(E) of
				true -> discover_file(E);
				false -> ok end;
	false -> case filelib:is_dir(FilePath) of
		true -> E = fs_entry(ParentId, FilePath, RuleIndex),
			case is_changed(E) of
				true -> discover_dir(E);
				false -> discover_dir_dir(E) end;
	false -> mydlp_mnesia:del_fs_entry(FilePath) end end, % Means file does not exists
	ok.

set_discover_inprog() ->
	mydlp_container:set_ep_meta("discover_inprog", "yes"),
	mydlp_sync:sync_now().

unset_discover_inprog() ->
	mydlp_container:set_ep_meta("discover_inprog", "no"),
	mydlp_sync:sync_now().
	
-endif.

