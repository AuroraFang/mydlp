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

-module(mydlp_discover_web).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_schema.hrl").

-include_lib("kernel/include/file.hrl").

%% API
-export([start_link/0,
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
	head_requests,
	get_requests,
	discover_queue,
	discover_inprog=false,
	timer
}).


q(WebServerId, PagePath) -> q(WebServerId, none, PagePath).

q(WebServerId, ParentId, PagePath) ->
	case mydlp_mnesia:get_web_server(WebServerId) of
		#web_server{dig_depth=Depth} -> q(WebServerId, ParentId, PagePath, Depth);
		_Else -> ok end.

q(_WebServerId, _ParentId, _PagePath, 0) -> ok;
q(WebServerId, ParentId, PagePath, Depth) -> gen_server:cast(?MODULE, {q, WebServerId, ParentId, PagePath, Depth}).

stop_discovery() -> gen_server:cast(?MODULE, stop_discovery).

schedule_discovery() -> gen_server:cast(?MODULE, schedule_discovery).

%%%%%%%%%%%%%% gen_server handles

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_cast({q, WebServerId, ParentId, PagePath, Depth}, #state{discover_queue=Q, discover_inprog=false} = State) ->
	Q1 = queue:in({WebServerId, ParentId, PagePath, Depth}, Q),
	consume(),
	set_discover_inprog(),
	{noreply, State#state{discover_queue=Q1, discover_inprog=true}};

handle_cast({q, WebServerId, ParentId, PagePath, Depth}, #state{discover_queue=Q, discover_inprog=true} = State) ->
	Q1 = queue:in({WebServerId, ParentId, PagePath, Depth}, Q),
	{noreply,State#state{discover_queue=Q1}};

handle_cast(consume, #state{discover_queue=Q, head_requests=HeadT} = State) ->
	case queue:out(Q) of
		{{value, {WebServerId, ParentId, PagePath, Depth}}, Q1} ->
			try 	case is_cached({WebServerId, PagePath}) of
					false -> case fetch_meta(WebServerId, PagePath) of
						{ok, RequestId} ->
							HeadT1 = gb_trees:enter(RequestId, {WebServerId, ParentId, PagePath, Depth}, HeadT),
							consume(),
							{noreply, State#state{discover_queue=Q1, head_requests=HeadT1}};
						external -> consume(),
							{noreply, State#state{discover_queue=Q1}} end;
					true -> consume(),
						{noreply, State#state{discover_queue=Q1}} end
			catch Class:Error ->
				?ERROR_LOG("Web: Discover Queue Consume: Error occured: "
						"Class: ["?S"]. Error: ["?S"].~n"
						"Stack trace: "?S"~nWebServerId: "?S" PagePath: "?S"~nState: "?S"~n ",	
						[Class, Error, erlang:get_stacktrace(), WebServerId, PagePath, State]),
					consume(),
					{noreply, State#state{discover_queue=Q1}} end;
		{empty, _} ->
			State1 = schedule_timer(State, ?CFG(discover_web_interval)),
			unset_discover_inprog(),
			{noreply, State1#state{discover_inprog=false}}
	end;

handle_cast(stop_discovery, State) ->
	NewQ = queue:new(),
	GetT = gb_tree:empty(),
	HeadT = gb_tree:empty(),
	{noreply, State#state{discover_queue=NewQ, get_requests=GetT, head_requests=HeadT}};

handle_cast(schedule_discovery, State) -> handle_info(schedule_now, State);

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({http, {RequestId, Result}}, #state{head_requests=HeadT, get_requests=GetT} = State) ->
	try	case gb_trees:is_defined(RequestId, HeadT) of
			true -> State1 =  handle_head(RequestId, Result, State), {noreply, State1};
		false -> case gb_trees:is_defined(RequestId, GetT) of
			true -> State1 = handle_get(RequestId, Result, State), {noreply, State1};
		false -> {noreply, State} end end
	catch Class:Error -> ?ERROR_LOG("Web: Discover Queue Consume: Error occured: "
		"Class: ["?S"]. Error: ["?S"].~n"
		"Stack trace: "?S"~nRequestId: "?S" Result: "?S"~nState: "?S"~n ",	
		[Class, Error, erlang:get_stacktrace(), RequestId, Result, State]),
		{noreply, State}
	end;

handle_info(schedule_now, State) ->
	State1 = cancel_timer(State),
	schedule(),
	{noreply, State1};

handle_info(schedule_startup, State) ->
	State1 = case ?CFG(discover_web_on_startup) of
		true -> schedule(), State;
		false -> schedule_timer(State, ?CFG(discover_web_interval)) end,
	{noreply, State1};

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info(_Info, State) -> 
	{noreply, State}.

%%%%%%%%%%%%%%%% Implicit functions

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
	reset_discover_cache(),
	WebServers = mydlp_mnesia:get_web_servers(),
	lists:map(fun(W) -> q(W#web_server.id, W#web_server.start_path) end, WebServers),
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
	inets:start(),
	timer:send_after(60000, schedule_startup),
	{ok, #state{discover_queue=queue:new(), head_requests=gb_trees:empty(), get_requests=gb_trees:empty()}}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%%%%%%% internal

get_base_url(W) ->
	case W of
		#web_server{proto="https", port=443} -> 
			"https://" ++ W#web_server.address ++ "/";
		#web_server{proto="http", port=80} -> 
			"http://" ++ W#web_server.address ++ "/";
		_ -> W#web_server.proto ++ "://" ++ W#web_server.address ++ ":" ++ 
			integer_to_list(W#web_server.port) ++ "/"  end.

get_url(WebServerId, PagePath) ->
	W = mydlp_mnesia:get_web_server(WebServerId),
	BaseURL = get_base_url(W),
	Path = drop_base(PagePath, BaseURL),
	case Path of
		external -> external;
		P -> BaseURL ++ P end.

drop_base("http://" ++ _, _BaseUrl) -> external;
drop_base("https://" ++ _, _BaseUrl) -> external;
drop_base("/" ++ Path, _BaseUrl) -> Path;
drop_base(PagePath, BaseUrl) -> 
	case string:str(PagePath, BaseUrl) of
		1 -> string:substr(PagePath, length(BaseUrl) + 1);
		_ -> PagePath end.

add_link_to_path(WebServerId, PagePath, Link) ->
	W = mydlp_mnesia:get_web_server(WebServerId),
	BaseURL = get_base_url(W),
	case drop_base(Link, BaseURL) of
		external -> external;
		P -> add_link_to_path1(PagePath, P) end.

add_link_to_path1(PagePath, LinkPath) ->
	case string:rchr(PagePath, $/) of
		0 -> LinkPath;
		I -> string:substr(PagePath, 1, I) ++ LinkPath end.

web_entry(WebServerId, PagePath, ParentId) ->
	EntryId = {WebServerId, PagePath},
	case mydlp_mnesia:get_web_entry(EntryId) of
		none ->	E = #web_entry{entry_id=EntryId, parent_id=ParentId},
			mydlp_mnesia:add_web_entry(E), %% bulk write may improve performance
			E;
		#web_entry{} = WE -> WE end.

fetch_meta(WebServerId, PagePath) ->
	URL = get_url(WebServerId, PagePath),
	case URL of
		external -> external;
		_ -> httpc:request(head, {URL, []}, [], [{sync, false}]) end.

is_changed(WebServerId, PagePath, ParentId, Headers) ->
	WE = web_entry(WebServerId, PagePath, ParentId),
	IsChanged = is_changed(WE, Headers),
	WE1 = update_web_entry(WE, Headers),
	mydlp_mnesia:add_web_entry(WE1),
	IsChanged.

is_changed(#web_entry{last_modified=undefined}, _Headers) -> true;
is_changed(#web_entry{maxage=undefined} = WE, _Headers) -> is_expired(WE);
is_changed(#web_entry{maxage=MA, last_modified=LM} = WE, _Headers) ->
	NowS = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
	LMS = calendar:datetime_to_gregorian_seconds(LM),
	case ( (NowS - LMS) > MA) of
		true -> is_expired(WE);
		false -> true end.

is_expired(#web_entry{expires=undefined}) -> true;
is_expired(#web_entry{expires=ED}) ->
	NowS = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
	EDS =  calendar:datetime_to_gregorian_seconds(ED),
	(NowS > EDS).

update_web_entry(WE, [{"content-type", "text/html" ++ _}|Headers]) -> 
	update_web_entry(WE#web_entry{is_html=true}, Headers);
update_web_entry(WE, [{"content-length", Size}|Headers]) -> 
	S = try	list_to_integer(Size)
	catch _:_ -> undefined end,
	update_web_entry(WE#web_entry{size=S}, Headers);
update_web_entry(WE, [{"last-modified", LMD}|Headers]) ->
	LM = case httpd_util:convert_request_date(LMD) of
		bad_date -> undefined;
		D -> D end,
	update_web_entry(WE#web_entry{last_modified=LM}, Headers);
update_web_entry(WE, [{"expires", ED} |Headers]) ->
	E = case httpd_util:convert_request_date(ED) of
		bad_date -> undefined;
		D -> D end,
	update_web_entry(WE#web_entry{expires=E}, Headers);
update_web_entry(WE, [{"cache-control",CacheS}| Headers]) ->
	MA = case string:str(CacheS, "max-age=") of
		0 -> undefined;
		I -> 	NextStr = string:substr(I + 8),
			case string:chr(NextStr, $\s) of
			0 -> undefined;
			I2 ->	case string:substr(NextStr, 1, I2 - 1) of
				"" -> undefined;
				Else -> try list_to_integer(Else)
					catch _:_ -> undefined end
				end
			end
		end,
	update_web_entry(WE#web_entry{maxage=MA}, Headers);
update_web_entry(WE, [_|Headers]) -> update_web_entry(WE, Headers);
update_web_entry(WE, []) -> WE.

fetch_data(WebServerId, PagePath) ->
	URL = get_url(WebServerId, PagePath),
	httpc:request(get, {URL, []}, [], [{sync, false}]).
	
handle_head(RequestId, {{_, 200, _}, Headers, <<>>}, #state{head_requests=HeadT, get_requests=GetT} = State) ->
	{WebServerId, ParentId, PagePath, Depth} = gb_trees:get(RequestId, HeadT),
	HeadT1 = gb_trees:delete(RequestId, HeadT),
	EntryId = {WebServerId, PagePath},
	GetT1 = case is_changed(WebServerId, PagePath, ParentId, Headers) of
		true -> case has_exceed_maxobj_size(EntryId) of
			false -> {ok, RequestId2} = fetch_data(WebServerId, PagePath),
				gb_trees:enter(RequestId2, {WebServerId, ParentId, PagePath, Depth}, GetT);
			true -> GetT end;
		false -> case is_html(EntryId) of
			true -> discover_cached_page(EntryId, Depth - 1);
			false -> ok end,
			GetT end,
	State#state{head_requests=HeadT1, get_requests=GetT1}.

handle_get(RequestId, {{_, 200, _}, _Headers, Data}, #state{get_requests=GetT} = State) ->
	{WebServerId, _ParentId, PagePath, Depth} = gb_trees:get(RequestId, GetT),
	GetT1 = gb_trees:delete(RequestId, GetT),
	EntryId = {WebServerId, PagePath},
	discover_item(EntryId, Data),
	case is_html(EntryId) of 
		true -> discover_links(EntryId, Data, Depth - 1);
		false -> ok end,
	State#state{get_requests=GetT1}.

get_fn(WebServerId, PagePath) -> 
	URL = get_url(WebServerId, PagePath),
	case string:rchr(URL, $/) of
		0 -> "data";
		I -> 	NextStr = string:substr(URL, I+1),
			case string:tokens(NextStr, "?=;&/") of
				[FN|_] -> case mydlp_api:do_prettify_uenc(FN) of
					{ok, PFN} -> mydlp_api:filename_to_list(PFN);
					_ -> "data" end;
				_ -> "data" 
				end
		end.

discover_item({WebServerId, PagePath}, Data) ->
	try	timer:sleep(20),
		{ok, ObjId} = mydlp_container:new(),
		ok = mydlp_container:setprop(ObjId, "channel", "web_discovery"),
		ok = mydlp_container:setprop(ObjId, "web_server_id", WebServerId),
		ok = mydlp_container:setprop(ObjId, "filename_unicode", get_fn(WebServerId, PagePath)),
		ok = mydlp_container:push(ObjId, Data),
		ok = mydlp_container:eof(ObjId),
		{ok, _Action} = mydlp_container:aclq(ObjId),
		ok = mydlp_container:destroy(ObjId)
	catch Class:Error ->
		?ERROR_LOG("DISCOVER FILE: Error occured: Class: ["?S"]. Error: ["?S"].~n"
				"Stack trace: "?S"~nWebServerId: "?S" PagePath: ["?S"].~n",
			[Class, Error, erlang:get_stacktrace(), WebServerId, PagePath])
	end,
	ok.

is_html(EntryId) ->
	W = mydlp_mnesia:get_web_entry(EntryId),
	case W#web_entry.is_html of
		true -> true;
		_Else -> false end.

has_exceed_maxobj_size(EntryId) ->
	W = mydlp_mnesia:get_web_entry(EntryId),
	
	case W#web_entry.size of
		undefined -> false;
		_ -> ( W#web_entry.size > ?CFG(maximum_object_size) ) end.

discover_links(_, _, 0) -> ok;
discover_links({_WebServerId, _PagePath} = EntryId, Data, Depth) ->
	Links = mydlp_tc:extract_links(Data),
	schedule_links(Links, EntryId, Depth).

schedule_links([L|Links], EntryId, Depth) when is_binary(L) ->
	schedule_links([binary_to_list(L)|Links],  EntryId, Depth);
schedule_links([L|Links], {WebServerId, PagePath} = EntryId, Depth) when is_list(L) ->
	LPath = add_link_to_path(WebServerId, PagePath, L),
	q(WebServerId, EntryId, LPath, Depth),
	schedule_links(Links, EntryId, Depth);
schedule_links([], _, _) -> ok.

discover_cached_page(_, 0) -> ok;
discover_cached_page({_WebServerId, _PagePath} = EntryId, Depth) ->
	Links = mydlp_mnesia:web_entry_list_links(EntryId),
	schedule_links(Links, EntryId, Depth).

set_discover_inprog() -> ok.

unset_discover_inprog() ->
	reset_discover_cache(),
	ok.

reset_discover_cache() ->
	put(cache, gb_sets:new()), ok.

is_cached(Element) ->
	CS = get(cache),
	case gb_sets:is_element(Element, CS) of
		true -> true;
		false -> CS1 = gb_sets:add(Element, CS),
			put(cache, CS1),
			false end.
	
