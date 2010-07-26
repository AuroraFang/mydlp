%
%%%    Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@medra.com.tr>
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
%%% @author H. Kerem Cevahir <kerem@medratech.com>
%%% @copyright 2010, H. Kerem Cevahir
%%% @doc Persistency api for mydlp.
%%% @end
%%%-------------------------------------------------------------------
-module(mydlp_mnesia).
-author("kerem@medra.com.tr").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_schema.hrl").

%% API
-export([start_link/0,
	get_cgid/0,
	get_pgid/0,
	get_rules/1,
	get_regexes/1,
	add_fhash/3,
	remove_fhash/1,
	remove_fhash_group/1,
	add_shash/3,
	remove_shash/1,
	remove_shash_group/1,
	set_gid_by_fid/2,
	is_fhash_of_gid/2,
	is_shash_of_gid/2,
	is_mime_of_gid/2,
	get_record_fields/1,
	stop/0]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-record(state, {}).

%%%%%%%%%%%%%%%% Table definitions

-define(TABLES, [
	filter, 
	rule, 
	ipr, 
	match, 
	match_group, 
	{file_hash, ordered_set, 
		fun() -> mnesia:add_table_index(file_hash, md5) end},
	{sentence_hash, ordered_set, 
		fun() -> mnesia:add_table_index(sentence_hash, phash2) end},
	{mime_type, ordered_set, 
		fun() -> mnesia:add_table_index(mime_type, mime) end},
	regex
]).


get_record_fields(Record) -> 
        case Record of
		unique_ids -> record_info(fields, unique_ids);
		filter -> record_info(fields, filter);
		rule -> record_info(fields, rule);
		ipr -> record_info(fields, ipr);
		match -> record_info(fields, match);
		match_group -> record_info(fields, match_group);
		file_hash -> record_info(fields, file_hash);
		sentence_hash -> record_info(fields, sentence_hash);
		mime_type -> record_info(fields, mime_type);
		regex -> record_info(fields, regex)
	end.

%%%%%%%%%%%%% MyDLP Mnesia API

get_cgid() -> -1.

get_pgid() -> -2.

get_rules(Who) -> 
	async_query_call({get_rules, Who}).

get_regexes(GroupId) ->	
	async_query_call({get_regexes, GroupId}).

add_fhash(Hash, FileId, GroupId) when is_binary(Hash) -> 
	async_query_call({add_fhash, Hash, FileId, GroupId}).

remove_fhash(FileId) -> async_query_call({remove_fhash, FileId}).

remove_fhash_group(GroupId) -> async_query_call({remove_fhash_group, GroupId}).

is_fhash_of_gid(Hash, GroupIds) -> 
	async_query_call({is_fhash_of_gid, Hash, GroupIds}).

add_shash(Hash, FileId, GroupId) when is_integer(Hash) -> add_shash([Hash], FileId, GroupId);
add_shash(HList, FileId, GroupId) when is_list(HList) -> 
	async_query_call({add_shl, HList, FileId, GroupId}).

remove_shash(FileId) -> async_query_call({remove_shash, FileId}).

remove_shash_group(GroupId) -> async_query_call({remove_shash_group, GroupId}).

is_shash_of_gid(Hash, GroupIds) -> 
	async_query_call({is_shash_of_gid, Hash, GroupIds}).

is_mime_of_gid(Mime, GroupIds) -> 
	async_query_call({is_mime_of_gid, Mime, GroupIds}).

set_gid_by_fid(FileId, GroupId) -> async_query_call({set_gid_by_fid, FileId, GroupId}).

%%%%%%%%%%%%%% gen_server handles

handle_result({is_mime_of_gid, _Mime, MGIs}, {atomic, GIs}) -> 
	lists:any(fun(I) -> lists:member(I, MGIs) end,GIs);

handle_result({is_shash_of_gid, _Hash, HGIs}, {atomic, GIs}) -> 
	lists:any(fun(I) -> lists:member(I, HGIs) end,GIs);

handle_result({is_fhash_of_gid, _Hash, HGIs}, {atomic, GIs}) -> 
	lists:any(fun(I) -> lists:member(I, HGIs) end,GIs);

handle_result(_Query, {atomic, Objects}) -> Objects.

handle_query({get_rules, Who}) ->
	Q = qlc:q([I#ipr.parent || I <- mnesia:table(ipr),
			ip_band(I#ipr.ipbase, I#ipr.ipmask) == ip_band(Who, I#ipr.ipmask)
			]),
	Parents = qlc:e(Q),
	Rules = resolve_rules(Parents),
	resolve_funcs(Rules);

handle_query({get_regexes, GroupId}) ->
	Q = qlc:q([R#regex.compiled ||
		R <- mnesia:table(regex),
		R#regex.group_id == GroupId
		]),
	qlc:e(Q);

handle_query({add_fhash, Hash, FI, GI}) ->
	NewId = get_unique_id(file_hash),
	FileHash = #file_hash{id=NewId, file_id=FI, group_id=GI, md5=Hash},
	mnesia:write(FileHash);

handle_query({remove_fhash, FI}) ->
	Q = qlc:q([H#file_hash.id ||
		H <- mnesia:table(file_hash),
		H#file_hash.file_id == FI
		]),
	FIDs = qlc:e(Q),
	lists:foreach(fun(Id) -> mnesia:delete({file_hash, Id}) end, FIDs);

handle_query({remove_fhash_group, GI}) ->
	Q = qlc:q([H#file_hash.id ||
		H <- mnesia:table(file_hash),
		H#file_hash.group_id == GI 
		]),
	FIDs = qlc:e(Q),
	lists:foreach(fun(Id) -> mnesia:delete({file_hash, Id}) end, FIDs);

handle_query({is_fhash_of_gid, Hash, _HGIs}) ->
	Q = qlc:q([H#file_hash.group_id ||
		H <- mnesia:table(file_hash),
		H#file_hash.md5 == Hash
		]),
	qlc:e(Q);

handle_query({add_shl, HList, FI, GI}) ->
	lists:foreach(fun(Hash) ->
		NewId = get_unique_id(sentence_hash),
		SentenceHash = #sentence_hash{id=NewId, file_id=FI, group_id=GI, phash2=Hash},
		mnesia:write(SentenceHash) 
	end, HList);

handle_query({remove_shash, FI}) ->
	Q = qlc:q([H#sentence_hash.id ||
		H <- mnesia:table(sentence_hash),
		H#sentence_hash.file_id == FI
		]),
	FIDs = qlc:e(Q),
	lists:foreach(fun(Id) -> mnesia:delete({sentence_hash, Id}) end, FIDs);

handle_query({remove_shash_group, GI}) ->
	Q = qlc:q([H#sentence_hash.id ||
		H <- mnesia:table(sentence_hash),
		H#sentence_hash.group_id == GI 
		]),
	FIDs = qlc:e(Q),
	lists:foreach(fun(Id) -> mnesia:delete({sentence_hash, Id}) end, FIDs);

handle_query({is_shash_of_gid, Hash, _HGIs}) ->
	Q = qlc:q([H#sentence_hash.group_id ||
		H <- mnesia:table(sentence_hash),
		H#sentence_hash.phash2 == Hash
		]),
	qlc:e(Q);

handle_query({is_mime_of_gid, Mime, _MGIs}) ->
	Q = qlc:q([M#mime_type.group_id ||
		M <- mnesia:table(mime_type),
		M#mime_type.mime == Mime
		]),
	qlc:e(Q);

handle_query({set_gid_by_fid, FI, GI}) ->
	Q = qlc:q([H#sentence_hash{group_id=GI} ||	
		H <- mnesia:table(sentence_hash),
		H#sentence_hash.file_id == FI ]),
	SHs = qlc:e(Q),
	Q2 = qlc:q([H#file_hash{group_id=GI} ||	
		H <- mnesia:table(file_hash),
		H#file_hash.file_id == FI ]),
	SH2s = qlc:e(Q2),
	lists:foreach(fun(H) -> mnesia:write(H) end, SHs),
	lists:foreach(fun(H) -> mnesia:write(H) end, SH2s);

handle_query(_Query) -> error.

handle_call({async_query, Query}, From, State) ->
	Worker = self(),
	spawn_link(fun() ->
		F = fun() -> handle_query(Query) end,
		Result = transaction(F),
		Return = handle_result(Query, Result),
		Worker ! {async_reply, Return, From}
	end),
	{noreply, State, 5000};

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_info({async_reply, Reply, From}, State) ->
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

init([]) ->
	mnesia:create_schema([node()]),
	mnesia:start(),

	start_table({unique_ids, set}),
	start_tables(?TABLES),

	consistency_chk(),

	{ok, #state{}}.

handle_cast(_Msg, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%%%%%%%

start_table(RecordAtom) when is_atom(RecordAtom) ->
	start_table({RecordAtom, ordered_set});

start_table({RecordAtom, TableType}) ->
	start_table({RecordAtom, TableType, fun() -> ok end});

start_table({RecordAtom, TableType, InitFun}) ->
	try
		mnesia:table_info(RecordAtom, type)
	catch
		exit: _ ->
			mnesia:create_table(RecordAtom,
					[{attributes, 
						get_record_fields(RecordAtom) },
						{type, TableType},
						{disc_copies, [node()]}]),

			transaction(InitFun)
	end.

start_tables([RecordAtom|RAList]) ->
	start_table(RecordAtom),
	start_tables(RAList);
start_tables([]) -> ok.

%get_unique_id(TableName) ->
%	mnesia:dirty_update_counter(unique_ids, TableName, 1).

transaction(F) ->
	try {atomic, mnesia:activity(transaction, F)}
	catch
		exit:Reason ->
			{aborted, Reason}
	end.

ip_band({A1,B1,C1,D1}, {A2,B2,C2,D2}) -> {A1 band A2, B1 band B2, C1 band C2, D1 band D2}.

resolve_rules(PS) -> resolve_rules(PS,[]).
resolve_rules([P|PS], Rules) -> resolve_rules(PS, [resolve_rule(P)| Rules]);
resolve_rules([], Rules) -> lists:reverse(Rules).

resolve_rule({mgroup, Id}) ->
	Q = qlc:q([MG#match_group.parent || 
			MG <- mnesia:table(match_group),
			MG#match_group.id == Id
			]),
	[Parent] = qlc:e(Q),
	resolve_rule(Parent);
resolve_rule({rule, Id}) ->
	Q = qlc:q([{R#rule.id, R#rule.action} || 
			R <- mnesia:table(rule), 
			R#rule.id == Id
			]),
	[Rule] = qlc:e(Q), Rule.
	
resolve_funcs(Rules) -> resolve_funcs(Rules,[]).
resolve_funcs([{Id,Action}|Rules], Results) -> 
	resolve_funcs(Rules, [{Id, Action, find_funcs({rule, Id})}|Results]);
resolve_funcs([], Results) -> lists:reverse(Results).

find_funcss(Parents) -> find_funcss(Parents, []).
find_funcss([Parent|Parents], Funcs) ->
	find_funcss(Parents, [find_funcs(Parent)|Funcs]);
find_funcss([], Funcs) -> lists:reverse(Funcs).

find_funcs(ParentId) ->
	QM = qlc:q([{M#match.func, M#match.func_params} ||
			M <- mnesia:table(match),
			M#match.parent == ParentId
		]),
	QMG = qlc:q([{mgroup, MG#match_group.id} ||
			MG <- mnesia:table(match_group),
			MG#match_group.parent == ParentId
		]),
	lists:flatten([qlc:e(QM), find_funcss(qlc:e(QMG))]).

consistency_chk() -> 
	compile_regex().

compile_regex() ->
	mnesia:wait_for_tables([regex], 5000),
	RegexC = fun() ->
		Q = qlc:q([R || R <- mnesia:table(regex),
			R#regex.plain /= undefined,
			R#regex.compiled == undefined,
			R#regex.error == undefined
			]),
		[mnesia:write(R) || R <- compile_regex(qlc:e(Q))]
	end,
	transaction(RegexC).

compile_regex(Regexs) -> compile_regex(Regexs, []).

compile_regex([R|RS], Ret) -> 
	R1 = case re:compile(R#regex.plain, [unicode, caseless]) of
		{ok, C} -> R#regex{compiled=C};
		{error, Err} -> R#regex{error=Err}
	end,
	compile_regex(RS, [R1|Ret]);
compile_regex([], Ret) -> lists:reverse(Ret).

get_unique_id(TableName) -> mnesia:dirty_update_counter(unique_ids, TableName, 1).

async_query_call(Query) -> gen_server:call(?MODULE, {async_query, Query}).

