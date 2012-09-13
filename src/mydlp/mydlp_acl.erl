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
%%% @copyright 2010, H. Kerem Cevahir
%%% @doc ACL for mydlp.
%%% @end
%%%-------------------------------------------------------------------

-module(mydlp_acl).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_acl.hrl").

%% API
-export([start_link/0,
	stop/0]).

-ifdef(__MYDLP_NETWORK).

-export([
	get_remote_rule_tables/2,
	q/2
	]).

-endif.

-ifdef(__MYDLP_ENDPOINT).

-endif.

-export([
	qi/2,
	qe/2
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
	is_multisite=false
	}).

%%%%%%%%%%%%% MyDLP ACL API

-ifdef(__MYDLP_NETWORK).

get_remote_rule_tables(Addr, UserH) -> acl_call({get_remote_rule_tables, Addr, UserH}).

q(AclQ, Files) -> acl_call({q, AclQ}, Files).

-endif.

-ifdef(__MYDLP_ENDPOINT).

-endif.

% For handling inbound request.
qi(Channel, Files) -> acl_call({qi, Channel}, Files).

qe(Channel, Files) -> acl_call({qe, Channel}, Files).

-ifdef(__MYDLP_NETWORK).

acl_call(Query) -> acl_call(Query, none).

-endif.

acl_call(Query, Files) -> acl_call(Query, Files, 1500000).

acl_call(Query, none, Timeout) -> acl_call1(Query, none, Timeout);
acl_call(Query, [#file{mime_type= <<"mydlp-internal/usb-device", _/binary>>}] = Files, Timeout) -> acl_call1(Query, Files, Timeout);
acl_call(Query, Files, Timeout) -> 
	FileSizes = lists:map(fun(F) -> ?BB_S(F#file.dataref) end, Files),
	TotalSize = lists:sum(FileSizes),
	case TotalSize > ?CFG(maximum_object_size) of
		true -> {log, mydlp_api:empty_aclr(Files, max_size_exceeded)};
		false -> acl_call1(Query, Files, Timeout) end.

% no need to call acl server for inbound requests.
acl_call1({qi, _Channel}, _Files, _Timeout) -> 
	case ?CFG(archive_inbound) of
		true -> {archive, mydlp_api:empty_aclr(none, archive_inbound)};
		false -> pass end;
acl_call1(Query, Files, Timeout) -> gen_server:call(?MODULE, {acl, Query, Files, Timeout}, Timeout).

%%%%%%%%%%%%%% gen_server handles

-ifdef(__MYDLP_NETWORK).

acl_exec(none, []) -> pass;
acl_exec(_RuleTables, []) -> pass;
acl_exec(RuleTables, Files) ->
	acl_exec2(RuleTables, Files).

-endif.

acl_exec2(none, _Files) -> pass;
acl_exec2({Req, {_Id, DefaultAction}, Rules}, Files) ->
	case { DefaultAction, acl_exec3(Req, Rules, Files) } of
		{DefaultAction, return} -> DefaultAction;
		{_DefaultAction, Action} -> Action end.

acl_exec3(_Req, [], _Files) -> return;
acl_exec3(_Req, _AllRules, []) -> return;
acl_exec3(Req, AllRules, Files) ->
	acl_exec3(Req, AllRules, Files, [], false).

acl_exec3(_Req, _AllRules, [], [], _CleanFiles) -> return;

acl_exec3(Req, AllRules, [], ExNewFiles, false) ->
	acl_exec3(Req, AllRules, [], ExNewFiles, true);

acl_exec3(Req, AllRules, [], ExNewFiles, CleanFiles) ->
	acl_exec3(Req, AllRules, ExNewFiles, [], CleanFiles);
	
acl_exec3(Req, AllRules, Files, ExNewFiles, CleanFiles) ->
	{InChunk, RestOfFiles} = mydlp_api:get_chunk(Files),
	Files1 = mydlp_api:load_files(InChunk),
	Files2 = drop_whitefile(Files1),

	{PFiles, NewFiles} = mydlp_api:analyze(Files2),
	PFiles1 = case CleanFiles of
		true -> mydlp_api:clean_files(PFiles); % Cleaning newly created files.
		false -> PFiles end,

	PFiles2 = drop_nodata(PFiles1),
	PFiles3 = case Req of
		#mining_req{normal_text = true} -> pl_text(PFiles2, normalized);
		#mining_req{raw_text = true} -> pl_text(PFiles2, raw_text);
		_Else2 -> PFiles2 end,

	PFiles4 = case Req of 
		#mining_req{mc_pd = true, mc_kw = true} -> mc_text(PFiles3, all);
		#mining_req{mc_pd = true} -> mc_text(PFiles3, pd);
		#mining_req{mc_kw = true} -> mc_text(PFiles3, kw);
		_Else3 -> mc_text(PFiles3, none) end,

	FFiles = PFiles4,

	CTX = ctx_cache(),
	AclR = case apply_rules(CTX, AllRules, FFiles) of
		return -> acl_exec3(Req, AllRules, RestOfFiles,
				lists:append(ExNewFiles, NewFiles), CleanFiles);
		Else -> Else end,
	ctx_cache_stop(CTX),
	AclR.

-ifdef(__MYDLP_NETWORK).

handle_acl({q, #aclq{} = AclQ}, Files, _State) ->
	CustomerId = mydlp_mnesia:get_dfid(),
	Rules = mydlp_mnesia:get_rules(CustomerId, AclQ),
	acl_exec(Rules, Files);

handle_acl({get_remote_rule_tables, Addr, UserH}, _Files, _State) ->
	CustomerId = mydlp_mnesia:get_dfid(),
	% TODO: change needed for multi-site use
	mydlp_mnesia:get_remote_rule_tables(CustomerId, Addr, UserH);

handle_acl(Q, _Files, _State) -> throw({error, {undefined_query, Q}}).

-endif.

-ifdef(__MYDLP_ENDPOINT).

handle_acl({qe, _Channel}, [#file{mime_type= <<"mydlp-internal/usb-device;id=unknown">>}] = Files, _State) ->
	{?CFG(error_action), mydlp_api:empty_aclr(Files, usb_device_id_unknown)};

handle_acl({qe, _Channel}, [#file{mime_type= <<"mydlp-internal/usb-device;id=", DeviceId/binary>>}] = Files, _State) ->
	case mydlp_mnesia:is_valid_usb_device_id(DeviceId) of % TODO: need refinements for multi-user usage.
		true -> pass;
		false -> {block, mydlp_api:empty_aclr(Files, usb_device_rejected)} end;

handle_acl({qe, Channel}, Files, _State) ->
	Rules = mydlp_mnesia:get_rule_table(Channel),
	acl_exec2(Rules, Files);

handle_acl(Q, _Files, _State) -> throw({error, {undefined_query, Q}}).

-endif.

handle_call({acl, Query, Files, Timeout}, From, State) ->
	Worker = self(),
	mydlp_api:mspawn(fun() ->
		Return = try 
			Result = handle_acl(Query, Files, State),
			{ok, Result}
		catch throw:{error,eacces} -> {error, {throw, {error,eaccess}}};
		      Class:Error ->
			?ERROR_LOG("Error occured on ACL query: ["?S"]. Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~n",
				[Query, Class, Error, erlang:get_stacktrace()]),
			{error, {Class,Error}} end,
		Worker ! {async_acl_q, Return, From} 
	end, Timeout),
	{noreply, State};

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_info({async_acl_q, Res, From}, State) ->
	Reply = case Res of
		{ok, R} -> R;
		{error, _} -> ?CFG(error_action) end, % TODO conf

	gen_server:reply(From, Reply),
	{noreply, State};

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

-ifdef(__MYDLP_NETWORK).

init([]) ->
	IsMS = mydlp_mysql:is_multisite(),
	{ok, #state{is_multisite=IsMS}}.

-endif.

-ifdef(__MYDLP_ENDPOINT).

init([]) ->
	{ok, #state{is_multisite=false}}.

-endif.

handle_cast(_Msg, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%%%%% helper func
apply_rules(_CTX, [], _Files) -> return;
apply_rules(_CTX, _Rules, []) -> return;
apply_rules(CTX, [{Id, Action, ITypes}|Rules], Files) ->
	case execute_itypes(CTX, ITypes, Files) of
		neg -> apply_rules(CTX, Rules, Files);
		{pos, {file, File}, {itype, ITypeOrigId}, {misc, Misc}} -> 
			{Action, {{rule, Id}, {file, File}, {itype, ITypeOrigId}, {misc, Misc}}};
		{error, {file, File}, {itype, ITypeOrigId}, {misc, Misc}} -> 
			{?CFG(error_action), {{rule, Id}, {file, File}, {itype, ITypeOrigId}, {misc, Misc}}}
	end.


execute_itypes(_CTX, [], _Files) -> neg;
execute_itypes(_CTX, _ITypes, []) -> neg;
execute_itypes(CTX, ITypes, Files) ->
	PAnyRet = mydlp_api:pany(fun(F) -> execute_itypes_pf(CTX, ITypes, F) end, Files, 900000),
	case PAnyRet of
		false -> neg;
		{ok, _File, Ret} -> Ret end.


execute_itypes_pf(CTX, ITypes, File) -> 
        File1 = case File#file.mime_type of 
                undefined -> 	MT = mydlp_tc:get_mime(File#file.filename, File#file.data),
				File#file{mime_type=MT};
                _Else ->	File end,

	PAnyRet = mydlp_api:pany(fun(T) -> execute_itype_pf(CTX, T, File1) end, ITypes, 850000),
	
	case PAnyRet of
		false -> neg;
		{ok, _IType, Ret} -> Ret end.

execute_itype_pf(CTX, {ITypeOrigId, all, Distance, IFeatures}, File) ->
	execute_itype_pf1(CTX, ITypeOrigId, Distance, IFeatures, File);
execute_itype_pf(CTX, {ITypeOrigId, DataFormats, Distance, IFeatures},
		#file{mime_type=MT} = File) ->
        case mydlp_mnesia:is_mime_of_dfid(MT, DataFormats) of
                false -> neg;
		true -> execute_itype_pf1(CTX, ITypeOrigId, Distance, IFeatures, File) end.

execute_itype_pf1(CTX, ITypeOrigId, Distance, IFeatures, File) ->
	case execute_ifeatures(CTX, Distance, IFeatures, File) of
		neg -> neg;
		pos -> {pos, {file, File}, {itype, ITypeOrigId}, {misc, ""}};
		{error, {file, File}, {misc, Misc}} ->
				{error, {file, File}, {itype, ITypeOrigId}, {misc, Misc}};
		E -> E end.

execute_ifeatures(_CTX, _Distance, [], _File) -> 0;
execute_ifeatures(CTX, Distance, IFeatures, File) ->
	try	UseDistance = case Distance of
			undefined -> false;
			_Else -> lists:all(fun({_Threshold, {_MId, Func, _FuncParams}}) ->
						is_distance_applicable(Func) end, IFeatures) end,
	
		PAllRet = mydlp_api:pall(fun({Threshold, {MId, Func, FuncParams}}) ->
						apply_m(CTX, Threshold, Distance, UseDistance, {MId, Func, FuncParams, File}) end,
					IFeatures, 800000),
		%%%% TODO: Check for PAnyRet whether contains error
		case {PAllRet, UseDistance} of
			{false, _} -> neg;
			{{ok, _Results}, false} -> pos;
			{{ok, Results}, true } -> is_distance_satisfied(Results, Distance) end
	catch _:{timeout, _F, _T} -> {error, {file, File}, {misc, timeout}} end.

%% Controls information feature is applicable for distance property.
is_distance_applicable(Func) ->
	{_, {distance, IsDistance}, {pd, _}, {kw, _}} = apply(Func, []), IsDistance.

is_distance_satisfied(Results, Distance) ->
	[ListOfIndexes, ListOfThresholds] = regulate_results(Results),
	%time to distance control
	[{I, _T}|_Tail] = ListOfIndexes,
	{TailOfIndexList, SubList} = find_in_distance(ListOfIndexes, Distance, I),
	is_in_valid_distance(TailOfIndexList, SubList, ListOfThresholds, Distance).

%% Controls whether fetching indexes are in a suitable distance or not. In addition; iterates all indexes.
is_in_valid_distance([], DistanceList,  ListOfThresholds, _Distance) -> 
	case is_all_thresholds_satisfied(DistanceList, ListOfThresholds) of
		true -> pos;
		false -> neg
	end;

is_in_valid_distance([{IV, _T}|Tail], [E], ListOfThresholds, Distance) ->
	case is_all_thresholds_satisfied([E], ListOfThresholds) of
		true -> pos;
		false -> {NewIndexList, NewDistanceList} = find_in_distance([{IV, _T}|Tail], Distance, IV),
			 is_in_valid_distance(NewIndexList, NewDistanceList, ListOfThresholds, Distance)
	end;

is_in_valid_distance(ListOfIndexes, DistanceList, ListOfThresholds, Distance) ->
	SumOfThresholds = lists:sum(ListOfThresholds),
	[_H1,{IndexValue, T}|TailOfDistanceList] = DistanceList,
	EarlyNeg = (length(DistanceList) < SumOfThresholds),
	case EarlyNeg of 
		true -> {TailOfIndexList, NewDistanceList} = find_in_distance(ListOfIndexes, Distance, IndexValue),
			is_in_valid_distance(TailOfIndexList, [{IndexValue, T}]++TailOfDistanceList++NewDistanceList, ListOfThresholds, Distance);
		false -> case is_all_thresholds_satisfied(DistanceList, ListOfThresholds) of
				true -> pos;
				false -> {TailOfIndexList, NewDistanceList} = find_in_distance(ListOfIndexes, Distance, IndexValue),
					is_in_valid_distance(TailOfIndexList, [{IndexValue, T}]++TailOfDistanceList++NewDistanceList, ListOfThresholds, Distance)
			 end
	end.

%% Controls whether list, which contains indexes in a certain distance, includes all information features in a certain amount of threshold.
is_all_thresholds_satisfied([], Acc) ->
	lists:all(fun(I) -> I =< 0 end, Acc);

is_all_thresholds_satisfied([{_I, T}|Tail], ThresholdList) ->
	Acc1 = lists:sublist(ThresholdList, T-1) ++ [lists:nth(T, ThresholdList) - 1] ++ lists:nthtail(T, ThresholdList),
	is_all_thresholds_satisfied(Tail, Acc1).

%% Returns remaining index list and the list which is in predefined distance.
find_in_distance(Results, Distance, IndexValue) -> find_in_distance(Results, Distance, IndexValue, []). 

find_in_distance([], _Distance, _IndexValue, Acc) -> {[],lists:reverse(Acc)};

find_in_distance([{IV, T}|Tail], Distance, IndexValue, Acc) ->
	case (IV =< (IndexValue+Distance)) of
		true -> find_in_distance(Tail, Distance, IndexValue, [{IV, T}|Acc]);
		false -> {[{IV, T}|Tail], lists:reverse(Acc)}
	end.

%% Puts flags to the index list, which index comes from which information feature.
regulate_results(Results) -> regulate_results(Results, 1, [], []).

regulate_results([], _Number, AccIndex, AccThreshold) ->
	IndexList = lists:keysort(1, lists:flatten(AccIndex)),
	[IndexList, lists:reverse(AccThreshold)];
		
regulate_results([Head|Tail], Number, AccIndex, AccThreshold) ->
	NewNumber = Number + 1,
	{pos, Threshold, {_Score, IndexList}} = Head, 
	IndexesWithNumbers = lists:map(fun(I) -> {I, Number} end, IndexList),
	regulate_results(Tail, NewNumber, [IndexesWithNumbers|AccIndex], [Threshold|AccThreshold]).

is_early_distance_satisfied([], _Threshold, _Distance) -> false;

is_early_distance_satisfied(_Indexes, 1 = _Threshold, _Distance) -> true;

is_early_distance_satisfied([_] = _Indexes, 1 = _Threshold, _Distance) -> true;

is_early_distance_satisfied([_] = _Indexes, _Threshold, _Distance) -> false;

is_early_distance_satisfied([Head|Tail], Threshold, Distance)->
	[Head2|_Tail2] = Tail,
	case ((Head2 - Head) =< Distance) of
		true -> true;
		false -> is_early_distance_satisfied(Tail, Threshold, Distance)
	end.

apply_m(_CTX, _Threshold, _Distance, _IsDistanceApplicable, {_MatcherId, all, _FuncParams, _File}) -> pos; %% match directly.
apply_m(CTX, Threshold, Distance, IsDistanceApplicable, {MatcherId, Func, FuncParams, File}) ->
	IsCachable = case File of
		#file{md5_hash=undefined} -> false;
		#file{md5_hash=_Else} -> true;
		_Else -> false end,
	case IsCachable of
		true -> apply_m_cached(CTX, Threshold, Distance, IsDistanceApplicable, {MatcherId, Func, FuncParams, File});
		false -> apply_func(Threshold, Distance, IsDistanceApplicable, {MatcherId, Func, FuncParams, File}) end.

apply_m_cached(CTX, Threshold, Distance, IsDistanceApplicable, {MatcherId, Func, FuncParams, File}) ->
	CacheKey = {File#file.md5_hash, Func, FuncParams},
	case ctx_start(CTX, CacheKey) of
		{ok, reserved} ->	Result = apply_func(Threshold, Distance, IsDistanceApplicable, {MatcherId, Func, FuncParams, File}),
					ctx_finish(CTX, CacheKey, Result), Result;
		{error, wait} ->	case ctx_wait(CTX, CacheKey) of
						{ok, Result} -> Result;
						{error, process_down} -> apply_m_cached(CTX, Threshold, Distance, IsDistanceApplicable, {MatcherId, Func, FuncParams, File})
					end;
		{error, result, Result} -> erlang:display(c_direct_result), Result end.

apply_func(Threshold, Distance, IsDistanceApplicable, {MatcherId, Func, FuncParams, File}) ->
	EarlyNeg = case is_text_func(Func) of
		false -> false;
		true -> not mydlp_api:has_text(File) end,
	case EarlyNeg of
		true -> neg;
		false -> FuncOpts = get_func_opts(Func, FuncParams),
			IndexRet = case is_mc_func(Func) of
				true -> apply(mydlp_matchers, mc_match, [MatcherId, Func, FuncOpts, File]);
				false -> apply(mydlp_matchers, Func, [{FuncOpts, File}]) end,
			case IndexRet of
				{Score, IndexList} ->
						EarlyNegForDistance = case IsDistanceApplicable of
										false -> true;
										true -> is_early_distance_satisfied(IndexList, Threshold, Distance)
									end,
						case ((Score >= Threshold) and EarlyNegForDistance) of
							true -> {pos, Threshold, {Score, IndexList}}; % TODO: Scores should be logged.
							false -> neg
						end;
				Score -> 
						case (Score >= Threshold) of
							true -> {pos, Threshold, {Score, dna}}; % TODO: Scores should be logged.
							false -> neg
						end
			end
	end.

is_mc_func(Func) ->
	case apply(mydlp_matchers, Func, []) of
		{_, {distance, _}, {pd, true}, {kw, _}} -> true;
		{_, {distance, _}, {pd, _}, {kw, true}} -> true;
		{_, {distance, _}, {pd, _}, {kw, _}} -> false end.

is_text_func(Func) ->
	case apply(mydlp_matchers, Func, []) of
		{raw, {distance, _}, {pd, _}, {kw, _}} -> false;
		{analyzed, {distance, _}, {pd, _}, {kw, _}} -> false;
		{text, {distance, _}, {pd, _}, {kw, _}} -> true;
		{normalized, {distance, _}, {pd, _}, {kw, _}} -> true end.

get_func_opts(Func, FuncParams) -> apply(mydlp_matchers, Func, [{conf, FuncParams}]).

pl_text(Files, Opts) -> lists:map(fun(F) -> pl_text_f(F, Opts) end, Files). % TODO: may be pmap used, should check thrift client high load conc

pl_text_f(#file{text=undefined} = File, Opts) -> 
	File1 = case mydlp_api:get_text(File) of
		{ok, Text} -> File#file{text = Text};
		{error, compression} -> File;
		{error, audio} -> File;
		{error, video} -> File;
		{error, image} -> File;
		_Else -> File#file{is_encrypted=true}
	end,
	File2 = case {File1#file.text, Opts} of
		{_, raw_text} -> File1;
		{undefined, _} -> File1;
		{RawText, normalized} ->
			NormalText = mydlp_nlp:normalize(RawText),
			File1#file{normal_text=NormalText};
		_Else2 -> File1 end,
	File2.

mc_text(Files, Opts) -> lists:map(fun(F) -> F#file{mc_table=mc_text_f(F, Opts)} end, Files). % TODO: may be pmap used, should check thrift client high load conc

mc_text_f(_, none) -> [];
mc_text_f(#file{normal_text=undefined}, _Opts) -> [];
mc_text_f(#file{normal_text=NormalText}, all) -> mydlp_mc:mc_search(NormalText);
mc_text_f(#file{normal_text=NormalText}, kw) -> mydlp_mc:mc_search(kw, NormalText);
mc_text_f(#file{normal_text=NormalText}, pd) -> mydlp_mc:mc_search(pd, NormalText).

is_whitefile(_File) ->
	%Hash = erlang:md5(File#file.data),
	%mydlp_mnesia:is_fhash_of_gid(Hash, [mydlp_mnesia:get_pgid()])
	false.

drop_whitefile(Files) -> lists:filter(fun(F) -> not is_whitefile(F) end, Files).

has_data(#file{dataref={cacheref, _Ref}}) -> true;
has_data(#file{dataref={memory, Bin}}) -> size(Bin) > 0;
has_data(#file{data=Data}) when is_binary(Data)-> size(Data) > 0;
has_data(Else) -> throw({error, unexpected_obj, Else}).

drop_nodata(Files) -> lists:filter(fun(F) -> has_data(F) end, Files).

%%%%%%%%%%%%%%%%%%%%% CTX Cache Start

-define(CTX_TIMEOUT, 900000).

ctx_cache() -> ctx_cache(?CTX_TIMEOUT).

ctx_cache(Timeout) -> mydlp_api:mspawn(fun() -> ctx_cache_func(Timeout) end, Timeout + 1000).

ctx_cache_stop(CTX) -> ok = ctx_query(CTX, stop).

ctx_cache_func(Timeout) ->
	receive
                {From, {start, Key}} -> ctx_cache_func_start(Timeout, From, Key);
                {From, {finish, Key, Result}} -> ctx_cache_func_finish(Timeout, From, Key, Result);
                {From, {wait, Key}} -> ctx_cache_func_wait(Timeout, From, Key);
		{'DOWN', _MonitorRef, process, Pid, _Info} -> ctx_cache_func_down(Timeout, Pid);
                {From, stop} -> ctx_cache_func_reply(From, ok);
		Else -> exit({error, unexpected_message_for_cache_main, Else})
        after Timeout + 500 ->
                exit({timeout, ctx_cache})
        end.

ctx_cache_func_reply(From, Message) -> From ! Message.

ctx_cache_func_down(Timeout, Pid) ->
	case get_keys({processing, Pid}) of
		[] -> ok;
		KeyList -> [ctx_cache_func_notify_down(K) || K <- KeyList] end,
	ctx_cache_func(Timeout).

ctx_cache_func_notify_down(Key) ->
	QueueList = case get({queue, Key}) of
		undefined -> 	[];
		L ->		L end,
	erase({queue, Key}),
	erase(Key),
	[P ! process_down || P <- QueueList], ok.
	

ctx_cache_func_start(Timeout, From, Key) ->
	case get(Key) of
		undefined -> 		monitor(process, From),
					put(Key, {processing, From}),
					ctx_cache_func_reply(From, {ok, reserved});
		{processing, _From} -> 	ctx_cache_func_reply(From, {error, wait});
		{result, Result} -> 	ctx_cache_func_reply(From, {error, result, Result}) end,
	ctx_cache_func(Timeout).

ctx_cache_func_notify_waiting(Key, Result) ->
	QueueList = case get({queue, Key}) of
		undefined -> 	[];
		L ->		L end,
	erase({queue, Key}),
	[P ! {finished, Result} || P <- QueueList], ok.
		
ctx_cache_func_finish(Timeout, From, Key, Result) ->
	case get(Key) of
		undefined -> 		exit({error, finishing_non_present_key});
		{processing, From} ->	put(Key, {result, Result}),
					ctx_cache_func_notify_waiting(Key, Result),
					ctx_cache_func_reply(From, ok);
		{processing, _Else} ->	exit({error, finishing_some_other_processes_key});
		{result, _Result} -> 	exit({error, finishing_alrady_finished_key}) end,
	ctx_cache_func(Timeout).

ctx_cache_func_add_queue(Key, From) ->
	case get({queue, Key}) of
		undefined -> 	put({queue, Key}, [From]);
		QueueList ->	put({queue, Key}, [From|QueueList]) end.
	
ctx_cache_func_wait(Timeout, From, Key) ->
	case get(Key) of
		undefined -> 		exit({error, waiting_for_non_present_key});
		{processing, _From} ->	ctx_cache_func_add_queue(Key, From),
					ctx_cache_func_reply(From, ok);
		{result, Result} -> 	ctx_cache_func_reply(From, {error, result, Result}) end,
	ctx_cache_func(Timeout).


ctx_start(CTX, Key) -> ctx_query(CTX, {start, Key}).

ctx_wait(CTX, Key) -> 
	case ctx_query(CTX, {wait, Key}) of
		{error, result, Result} -> {ok, Result};
		ok ->	receive
				{finished, Result} -> {ok, Result};
				process_down -> {error, process_down};
				Else -> exit({error, unexpected_message_when_waiting, Else})
			after ?CTX_TIMEOUT ->
				exit({timeout, ctx_query_wait})
			end
	end.

ctx_finish(CTX, Key, Result) -> ok = ctx_query(CTX, {finish, Key, Result}).

ctx_query(CTX, Message) -> ctx_query(CTX, Message, ?CTX_TIMEOUT).

ctx_query(CTX, Message, Timeout) ->
	CTX ! {self(), Message},
	receive
		Reply -> Reply
        after Timeout ->
                exit({timeout, ctx_query})
        end.

%%%%%%%%%%%%%%%%%%% CTX Cache end
