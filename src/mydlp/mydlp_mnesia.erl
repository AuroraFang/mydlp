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
%%% @doc Persistency api for mydlp.
%%% @end
%%%-------------------------------------------------------------------

-module(mydlp_mnesia).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_schema.hrl").

%% API
-export([start_link/0,
	stop/0]).


%% API common
-export([
	get_unique_id/1,
	compile_regex/0,
	get_cgid/0,
	get_pgid/0,
	get_dcid/0,
	get_drid/0,
	wait_for_tables/0,
	get_regexes/1,
	is_fhash_of_gid/2,
	is_shash_of_gid/2,
	is_mime_of_dfid/2,
	is_dr_fh_of_fid/2,
	get_record_fields/1,
	dump_tables/1,
	dump_client_tables/0,
	truncate_all/0,
	truncate_nondata/0,
	truncate_bayes/0,
	write/1,
	delete/1,
	flush_cache/0
	]).

-ifdef(__MYDLP_NETWORK).

%API network
-export([
	new_authority/1,
	get_mnesia_nodes/0,
	get_rules/1,
	get_all_rules/0,
	get_all_rules/1,
	get_rules_for_cid/2,
	get_rules_for_cid/3,
	get_rules_by_user/1,
	get_cid/1,
	remove_site/1,
	remove_file_entry/1,
	remove_group/1,
	remove_file_from_group/2,
	add_fhash/3,
	add_shash/3,
	set_gid_by_fid/2
	]).

-endif.

-ifdef(__MYDLP_ENDPOINT).

% API endpoint 
-export([
	get_rule_table/0,
	is_valid_usb_device_id/1
	]).

-endif.

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

-define(CLIENT_TABLES, [
	mime_type,
	file_hash,
	usb_device,
	sentence_hash,
	bayes_item_count,
	bayes_positive,
	bayes_negative,
	regex
]).

-define(OTHER_DATA_TABLES,[
	{file_hash, ordered_set, 
		fun() -> mnesia:add_table_index(file_hash, md5) end},
	{usb_device, ordered_set, 
		fun() -> mnesia:add_table_index(usb_device, device_id) end},
	{sentence_hash, ordered_set, 
		fun() -> mnesia:add_table_index(sentence_hash, phash2) end},
	{file_group, ordered_set, 
		fun() -> mnesia:add_table_index(file_group, file_id) end}
]).

-define(BAYES_TABLES, [
	{bayes_item_count, set},
	{bayes_positive, set},
	{bayes_negative, set}
]).

-define(DATA_TABLES, lists:append(?OTHER_DATA_TABLES, ?BAYES_TABLES)).

-ifdef(__MYDLP_NETWORK).

-define(NONDATA_FUNCTIONAL_TABLES, [
	filter,
	rule,
	ipr, 
	{m_user, ordered_set, 
		fun() -> mnesia:add_table_index(m_user, username) end},
	itype,
	ifeature,
	match, 
	site_desc
]).

-endif.

-ifdef(__MYDLP_ENDPOINT).

-define(NONDATA_FUNCTIONAL_TABLES, [
	{rule_table, ordered_set, 
		fun() -> mnesia:add_table_index(rule_table, head) end}
]).

-endif.

-define(NONDATA_COMMON_TABLES, [
	{mime_type, ordered_set, 
		fun() -> mnesia:add_table_index(mime_type, mime) end},
	{regex, ordered_set, 
		fun() -> mnesia:add_table_index(regex, group_id) end}
]).

-define(NONDATA_TABLES, lists:append(?NONDATA_FUNCTIONAL_TABLES, ?NONDATA_COMMON_TABLES)).

-define(TABLES, lists:append(?DATA_TABLES, ?NONDATA_TABLES)).

get_record_fields_common(Record) -> 
        case Record of
		unique_ids -> record_info(fields, unique_ids);
		usb_device -> record_info(fields, usb_device);
		file_hash -> record_info(fields, file_hash);
		sentence_hash -> record_info(fields, sentence_hash);
		file_group -> record_info(fields, file_group);
		mime_type -> record_info(fields, mime_type);
		regex -> record_info(fields, regex);
		bayes_item_count -> record_info(fields, bayes_item_count);
		bayes_positive -> record_info(fields, bayes_positive);
		bayes_negative -> record_info(fields, bayes_negative);
		_Else -> not_found
	end.

-ifdef(__MYDLP_NETWORK).

get_record_fields_functional(Record) ->
        case Record of
		filter -> record_info(fields, filter);
		rule -> record_info(fields, rule);
		ipr -> record_info(fields, ipr);
		m_user -> record_info(fields, m_user);
		itype -> record_info(fields, itype);
		ifeature -> record_info(fields, ifeature);
		match -> record_info(fields, match);
		site_desc -> record_info(fields, site_desc);
		_Else -> not_found
	end.

-endif.

-ifdef(__MYDLP_ENDPOINT).

get_record_fields_functional(Record) ->
        case Record of
		rule_table -> record_info(fields, rule_table);
		_Else -> not_found
	end.

-endif.

get_record_fields(Record) -> 
	case get_record_fields_common(Record) of
		not_found -> get_record_fields_functional(Record);
		Else -> Else end.

%-define(QLCQ(ListC), qlc:q(ListC, [{cache, ets}])).

%-define(QLCE(Query), qlc:e(Query, [{cache_all, ets}])).

-define(QLCQ(ListC), qlc:q(ListC)).

-define(QLCE(Query), qlc:e(Query)).

%%%%%%%%%%%%% MyDLP Mnesia API

get_cgid() -> -1.

get_pgid() -> -2.

get_dcid() -> 1.

get_drid() -> 0.

wait_for_tables() ->
	TableList = lists:map( fun
			({RecordAtom,_,_}) -> RecordAtom;
			({RecordAtom,_}) -> RecordAtom;
			(RecordAtom) when is_atom(RecordAtom) -> RecordAtom
		end, ?TABLES),
	mnesia:wait_for_tables(TableList, 15000).

-ifdef(__MYDLP_NETWORK).

get_rules(Who) -> aqc({get_rules, Who}, cache).

get_all_rules() -> aqc(get_all_rules, cache).

get_all_rules(DestList) -> aqc({get_all_rules, DestList}, cache).

get_rules_for_cid(FilterId, Who) -> get_rules_for_cid(FilterId, [], Who).

get_rules_for_cid(FilterId, DestList, Who) -> aqc({get_rules_for_cid, FilterId, DestList, Who}, cache).

get_rules_by_user(Who) -> aqc({get_rules_by_user, Who}, cache).

get_cid(SIpAddr) -> aqc({get_cid, SIpAddr}, cache).

remove_site(FilterId) -> aqc({remove_site, FilterId}, flush).

remove_file_entry(FileId) -> aqc({remove_file_entry, FileId}, flush).

remove_group(GroupId) -> aqc({remove_group, GroupId}, flush).

remove_file_from_group(FileId, GroupId) -> aqc({remove_file_from_group, FileId, GroupId}, flush).

add_fhash(Hash, FileId, GroupId) when is_binary(Hash) -> 
	aqc({add_fhash, Hash, FileId, GroupId}, flush).

add_shash(Hash, FileId, GroupId) when is_integer(Hash) -> add_shash([Hash], FileId, GroupId);
add_shash(HList, FileId, GroupId) when is_list(HList) -> 
	aqc({add_shl, HList, FileId, GroupId}, flush).

set_gid_by_fid(FileId, GroupId) -> aqc({set_gid_by_fid, FileId, GroupId}, flush).

new_authority(Node) -> gen_server:call(?MODULE, {new_authority, Node}, 30000).

-endif.

-ifdef(__MYDLP_ENDPOINT).

get_rule_table() -> aqc(get_rule_table, cache).

is_valid_usb_device_id(DeviceId) -> aqc({is_valid_usb_device_id, DeviceId}, cache).

-endif.

dump_tables(Tables) when is_list(Tables) -> aqc({dump_tables, Tables}, cache);
dump_tables(Table) -> dump_tables([Table]).

dump_client_tables() -> dump_tables(?CLIENT_TABLES).

get_regexes(GroupId) ->	aqc({get_regexes, GroupId}, cache).

is_fhash_of_gid(Hash, GroupIds) -> 
	aqc({is_fhash_of_gid, Hash, GroupIds}, nocache).

is_shash_of_gid(Hash, GroupIds) -> 
	aqc({is_shash_of_gid, Hash, GroupIds}, nocache).

is_mime_of_dfid(Mime, DataFormatIds) -> 
	aqc({is_mime_of_dfid, Mime, DataFormatIds}, cache).

is_dr_fh_of_fid(Hash, FileId) -> aqc({is_dr_fh_of_fid, Hash, FileId}, nocache).

write(RecordList) when is_list(RecordList) -> aqc({write, RecordList}, flush);
write(Record) when is_tuple(Record) -> write([Record]).

delete(Item) -> aqc({delete, Item}, flush).

truncate_all() -> gen_server:call(?MODULE, truncate_all, 15000).

truncate_nondata() -> gen_server:call(?MODULE, truncate_nondata, 15000).

truncate_bayes() -> gen_server:call(?MODULE, truncate_bayes, 15000).

flush_cache() -> cache_clean0().

%%%%%%%%%%%%%% gen_server handles

handle_result({is_mime_of_dfid, _Mime, DFIs}, {atomic, MDFIs}) -> 
	lists:any(fun(I) -> lists:member(I, DFIs) end, MDFIs);

handle_result({is_shash_of_gid, _Hash, HGIs}, {atomic, GIs}) -> 
	lists:any(fun(I) -> lists:member(I, HGIs) end,GIs);

handle_result({is_fhash_of_gid, _Hash, HGIs}, {atomic, GIs}) -> 
	lists:any(fun(I) -> lists:member(I, HGIs) end,GIs);

% TODO: instead of case statements, refining function definitions will make queries faster.
handle_result({get_cid, _SIpAddr}, {atomic, Result}) -> 
	case Result of
		[] -> nocustomer;
		[FilterId] -> FilterId end;

handle_result({is_dr_fh_of_fid, _, _}, {atomic, Result}) -> 
	case Result of
		[] -> false;
		Else when is_list(Else) -> true end;

%% TODO: endpoint specific code
handle_result(get_rule_table, {atomic, Result}) -> 
	case Result of
		[] -> [];
		[Table] -> Table end;

handle_result({is_valid_usb_device_id, _DeviceId}, {atomic, Result}) -> 
	case Result of
		[] -> false;
		[_|_] -> true end;

handle_result(_Query, {atomic, Objects}) -> Objects.

-ifdef(__MYDLP_NETWORK).

handle_query({get_rules_for_cid, FilterId, _DestList, Who}) ->
	Q = ?QLCQ([{R#rule.id, R#rule.orig_id, R#rule.action} || 
			R <- mnesia:table(rule),
			I <- mnesia:table(ipr),
			R#rule.filter_id == FilterId,
			I#ipr.rule_id == R#rule.id,
			ip_band(I#ipr.ipbase, I#ipr.ipmask) == ip_band(Who, I#ipr.ipmask)
			]),
	Rules = ?QLCE(Q),
	resolve_all(Rules, FilterId);

handle_query({get_rules, Who}) ->
	Q = ?QLCQ([{R#rule.id, R#rule.orig_id, R#rule.action} || 
			R <- mnesia:table(rule),
			I <- mnesia:table(ipr),
			I#ipr.rule_id == R#rule.id,
			ip_band(I#ipr.ipbase, I#ipr.ipmask) == ip_band(Who, I#ipr.ipmask)
			]),
	Rules = ?QLCE(Q),
	resolve_all(Rules);

handle_query(get_all_rules) ->
	Q = ?QLCQ([{R#rule.id, R#rule.orig_id, R#rule.action} || 
			F <- mnesia:table(filter),
			R <- mnesia:table(rule),
			R#rule.filter_id == F#filter.id
			]),
	Rules = ?QLCE(Q),
	resolve_all(Rules);

handle_query({get_all_rules, _DestList}) ->
	Q = ?QLCQ([{R#rule.id, R#rule.orig_id, R#rule.action} || 
			F <- mnesia:table(filter),
			R <- mnesia:table(rule),
			R#rule.filter_id == F#filter.id
			]),
	Rules = ?QLCE(Q),
	resolve_all(Rules);

handle_query({get_rules_by_user, Who}) ->
	Q = ?QLCQ([{R#rule.id, R#rule.orig_id, R#rule.action} || 
			R <- mnesia:table(rule),
			U <- mnesia:table(m_user),
			U#m_user.rule_id == R#rule.id,
			U#m_user.username == Who
			]),
	Rules = ?QLCE(Q),
	resolve_all(Rules);

handle_query({get_cid, SIpAddr}) ->
	Q = ?QLCQ([S#site_desc.filter_id ||
		S <- mnesia:table(site_desc),
		S#site_desc.ipaddr == SIpAddr
		]),
	?QLCE(Q);

handle_query({remove_site, FI}) ->
	Q4 = ?QLCQ([S#site_desc.ipaddr ||	
		S <- mnesia:table(site_desc),
		S#site_desc.filter_id == FI
		]),
	RQ4 = ?QLCE(Q4),

	Q7 = ?QLCQ([U#usb_device.id ||	
		U <- mnesia:table(usb_device),
		U#usb_device.filter_id == FI
		]),
	UDIs = ?QLCE(Q7),

	case RQ4 of
		[] -> ok;
		[SDI] -> mnesia:delete({site_desc, SDI}) end,

	remove_filters([FI]),
	lists:foreach(fun(Id) -> mnesia:delete({usb_device, Id}) end, UDIs);

handle_query({remove_file_entry, FI}) ->
	Q = ?QLCQ([H#file_hash.id ||
		H <- mnesia:table(file_hash),
		H#file_hash.file_id == FI
		]),
	FHIs = ?QLCE(Q),

	Q2 = ?QLCQ([H#sentence_hash.id ||
		H <- mnesia:table(sentence_hash),
		H#sentence_hash.file_id == FI
		]),
	SHIs = ?QLCE(Q2),

	Q3 = ?QLCQ([G#file_group.id ||	
		G <- mnesia:table(file_group),
		G#file_group.file_id == FI
		]),
	FGIs = ?QLCE(Q3),

	lists:foreach(fun(Id) -> mnesia:delete({file_hash, Id}) end, FHIs),
	lists:foreach(fun(Id) -> mnesia:delete({sentence_hash, Id}) end, SHIs),
	lists:foreach(fun(Id) -> mnesia:delete({file_group, Id}) end, FGIs);

handle_query({remove_group, GI}) ->
	Q = ?QLCQ([G#file_group.id ||
		G <- mnesia:table(file_group),
		G#file_group.group_id == GI 
		]),
	FGIs = ?QLCE(Q),
	lists:foreach(fun(Id) -> mnesia:delete({file_group, Id}) end, FGIs);

handle_query({remove_file_from_group, FI, GI}) ->
	Q = ?QLCQ([G#file_group.id ||
		G <- mnesia:table(file_group),
		G#file_group.file_id == FI,
		G#file_group.group_id == GI
		]),
	FGIs = ?QLCE(Q),
	lists:foreach(fun(Id) -> mnesia:delete({file_group, Id}) end, FGIs);

handle_query({add_fhash, Hash, FI, GI}) ->
	NewId = get_unique_id(file_hash),
	FileHash = #file_hash{id=NewId, file_id=FI, md5=Hash},
	mnesia:write(FileHash),
	add_file_group(FI, GI);

handle_query({add_shl, HList, FI, GI}) ->
	lists:foreach(fun(Hash) ->
		NewId = get_unique_id(sentence_hash),
		SentenceHash = #sentence_hash{id=NewId, file_id=FI, phash2=Hash},
		mnesia:write(SentenceHash),
		add_file_group(FI, GI)
	end, HList);

handle_query({set_gid_by_fid, FI, GI}) -> add_file_group(FI, GI);

handle_query(Query) -> handle_query_common(Query).

-endif.

-ifdef(__MYDLP_ENDPOINT).

% TODO: should be refined for multi-site usage
handle_query(get_rule_table) ->
	Q = ?QLCQ([ R#rule_table.table ||
		R <- mnesia:table(rule_table),
		R#rule_table.id == mydlp_mnesia:get_dcid()
		]),
	?QLCE(Q);

% TODO: should be refined for multi-site usage
handle_query({is_valid_usb_device_id, DeviceId}) ->
	Q = ?QLCQ([ U#usb_device.id ||
		U <- mnesia:table(usb_device),
		U#usb_device.device_id == DeviceId,
		U#usb_device.customer_id == mydlp_mnesia:get_dcid(),
		U#usb_device.action == pass
		]),
	?QLCE(Q);

handle_query(Query) -> handle_query_common(Query).

-endif.

handle_query_common({is_fhash_of_gid, Hash, _HGIs}) ->
	Q = ?QLCQ([G#file_group.group_id ||
		H <- mnesia:table(file_hash),
		G <- mnesia:table(file_group),
		H#file_hash.md5 == Hash,
		H#file_hash.file_id == G#file_group.file_id
		]),
	?QLCE(Q);

handle_query_common({is_shash_of_gid, Hash, _HGIs}) ->
	Q = ?QLCQ([G#file_group.group_id ||
		H <- mnesia:table(sentence_hash),
		G <- mnesia:table(file_group),
		H#sentence_hash.phash2 == Hash,
		H#sentence_hash.file_id == G#file_group.file_id
		]),
	?QLCE(Q);

handle_query_common({is_mime_of_dfid, Mime, _DFIs}) ->
	Q = ?QLCQ([M#mime_type.data_format_id ||
		M <- mnesia:table(mime_type),
		M#mime_type.mime == Mime
		]),
	?QLCE(Q);

handle_query_common({is_dr_fh_of_fid, Hash, FileId}) ->
	Q = ?QLCQ([F#file_hash.id ||
		F <- mnesia:table(file_hash),
		F#file_hash.file_id == FileId,
		F#file_hash.md5 == Hash
		]),
	?QLCE(Q);

handle_query_common({get_regexes, GroupId}) ->
	Q = ?QLCQ([ R#regex.compiled ||
		R <- mnesia:table(regex),
		R#regex.group_id == GroupId
		]),
	?QLCE(Q);

handle_query_common({dump_tables, Tables}) ->
	L1 = [ {T, mnesia:all_keys(T)} || T <- Tables],
	L2 = [ [ mnesia:read({T,K}) || K <- Keys ]  || {T, Keys} <- L1 ],
	L3 = lists:append(L2),
	lists:append(L3);

handle_query_common({write, RecordList}) when is_list(RecordList) ->
	lists:foreach(fun(R) -> mnesia:write(R) end, RecordList);

handle_query_common({delete, Item}) ->
	mnesia:delete(Item);

handle_query_common(Query) -> throw({error,{unhandled_query,Query}}).

handle_async_query(flush, Query) ->
	Return = evaluate_query(Query),
	cache_clean(),
	Return;

handle_async_query(cache, Query) ->
	case cache_lookup(Query) of
		{hit, {Query, R}} -> R;
		miss ->	R = evaluate_query(Query),
			cache_insert(Query, R),
			R end;

handle_async_query(nocache, Query) ->
	evaluate_query(Query).

handle_call({async_query, CacheOption, Query}, From, State) ->
	Worker = self(),
	mydlp_api:mspawn(fun() ->
		Return= try	handle_async_query(CacheOption, Query)
			catch  	Class:Error ->
				?ERROR_LOG("MNESIAQ: Error occured: Class: ["?S"]. Error: ["?S"].~n"
						"Stack trace: "?S"~n"
						"CacheOption: ["?S"]. Query: ["?S"]~n"
						"State: "?S"~n ",
					[Class, Error, erlang:get_stacktrace(), CacheOption, Query, State]),
					{ierror, {Class, Error}} end,
		Worker ! {async_reply, Return, From}
	end, 15000),
	{noreply, State};

handle_call(truncate_all, From, State) ->
	Worker = self(),
	?ASYNC(fun() ->
		lists:foreach(fun(T) -> mnesia:clear_table(T) end, all_tab_names()),
		lists:foreach(fun(T) -> mydlp_mnesia:delete({unique_ids, T}) end, all_tab_names()),
		cache_clean(),
		Worker ! {async_reply, ok, From}
	end, 15000),
	{noreply, State};

handle_call(truncate_nondata, From, State) ->
	Worker = self(),
	?ASYNC(fun() ->
		lists:foreach(fun(T) -> mnesia:clear_table(T) end, nondata_tab_names()),
		lists:foreach(fun(T) -> mydlp_mnesia:delete({unique_ids, T}) end, nondata_tab_names()),
		cache_clean(),
		Worker ! {async_reply, ok, From}
	end, 15000),
	{noreply, State};

handle_call(truncate_bayes, From, State) ->
	Worker = self(),
	?ASYNC(fun() ->
		lists:foreach(fun(T) -> mnesia:clear_table(T) end, bayes_tab_names()),
		cache_clean(),
		Worker ! {async_reply, ok, From}
	end, 15000),
	{noreply, State};

handle_call({new_authority, AuthorNode}, _From, State) ->
	MnesiaNodes = get_mnesia_nodes(),
	case lists:member(AuthorNode, MnesiaNodes) of
		false -> force_author(AuthorNode);
		true -> ok end,
	{reply, ok, State};

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info(cleanup_now, State) ->
	cache_cleanup_handle(),
	call_timer(),
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

is_mydlp_distributed() -> mydlp_distributor:is_distributed().

-endif.

-ifdef(__MYDLP_ENDPOINT).

is_mydlp_distributed() -> false.

-endif.

init([]) ->
	mnesia_configure(),

	case is_mydlp_distributed() of
		true -> start_distributed();
		false -> start_single() end,

	cache_start(),
	call_timer(),
	{ok, #state{}}.

handle_cast(_Msg, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%%%%%%%

mnesia_configure() ->
        MnesiaDir = case os:getenv("MYDLP_MNESIA_DIR") of
                false -> ?CFG(mnesia_dir);
                Path -> Path end,
	application:load(mnesia),
	application_controller:set_env(mnesia, dir, MnesiaDir),
	ok.

get_mnesia_nodes() -> mnesia:system_info(db_nodes).

start_single() ->
	start_mnesia_simple(),
	start_tables(false),
	ok.

start_distributed() ->
	IsAlreadyDistributed = is_mnesia_distributed(),
	case start_mnesia_distributed(IsAlreadyDistributed) of
		ok -> start_tables(true);
		{error, _} -> start_tables(false) end,
	MnesiaNodes = get_mnesia_nodes(),
	mydlp_distributor:bcast_cluster(MnesiaNodes),
	ok.

force_author(AuthorNode) -> 
	mnesia:stop(),
	case start_mnesia_with_author(AuthorNode) of
		ok -> start_tables(true);
		{error, _} -> start_tables(false) end,
	ok.

start_mnesia_distributed(true = _IsAlreadyDistributed) -> 
	start_mnesia_simple(),
	ok;

start_mnesia_distributed(false = _IsAlreadyDistributed) -> 
	case mydlp_distributor:find_authority() of
		none -> start_mnesia_simple(), {error, cannot_find_an_authority};
		AuthorNode -> start_mnesia_with_author(AuthorNode) end.

start_mnesia_simple() ->
	mnesia:create_schema([node()]), 
	mnesia:start().

start_mnesia_with_author(AuthorNode) ->
	mnesia:delete_schema([node()]),
	mnesia:start(),
	case mnesia:change_config(extra_db_nodes, [AuthorNode]) of
		{ok, []} -> {error, cannot_connect_to_any_other_node};
		{ok, [_|_]} -> mnesia:change_table_copy_type(schema, node(), disc_copies), ok;
		Else -> {error, Else} end.

is_mnesia_distributed() ->
	ThisNode = node(),
	case mnesia:system_info(db_nodes) of
		[ThisNode] -> false;
		DBNodeList -> lists:member(ThisNode, DBNodeList) end.

cache_start() ->
	ets:new(query_cache, [
			public,
			named_table,
			{write_concurrency, true}
			%{read_concurrency, true}
		]).

-ifdef(__MYDLP_NETWORK).

repopulate_mnesia() -> mydlp_mysql:repopulate_mnesia().

-endif.

-ifdef(__MYDLP_ENDPOINT).

repopulate_mnesia() -> ok.

-endif.

start_tables(IsDistributionInit) ->
	start_table(IsDistributionInit, {unique_ids, set}),
	StartResult =  start_tables(IsDistributionInit, ?TABLES),

	consistency_chk(),

	case StartResult of
		{ok, no_change} -> ok;
		{ok, schema_changed} -> repopulate_mnesia() end,
	ok.

start_table(IsDistributionInit, RecordAtom) when is_atom(RecordAtom) ->
	start_table(IsDistributionInit, {RecordAtom, ordered_set});

start_table(IsDistributionInit, {RecordAtom, TableType}) ->
	start_table(IsDistributionInit, {RecordAtom, TableType, fun() -> ok end});

start_table(false = _IsDistributionInit, Table) -> init_table(Table);

start_table(true = _IsDistributionInit, {RecordAtom, _, _}) -> 
	LocalTables = mnesia:system_info(local_tables),
	case lists:member(RecordAtom, LocalTables) of
		false -> mnesia:add_table_copy(RecordAtom, node(), disc_copies);
		true -> ok end, ok.

init_table({RecordAtom, TableType, InitFun}) ->
	RecordAttributes = get_record_fields(RecordAtom),

	TabState = try
		case mnesia:table_info(RecordAtom, attributes) of
			RecordAttributes -> ok;
			_Else -> recreate  % it means that schema had been updated, should recreate tab.
		end 
	catch
		exit: _ -> create % it means that there is no tab in database as specified.
	end,

	case TabState of
		ok -> 		ok;
		create -> 	create_table(RecordAtom, RecordAttributes, TableType, InitFun), 
				changed;
		recreate -> 	mnesia:wait_for_tables([RecordAtom], 5000),
				delete_table(RecordAtom),
				create_table(RecordAtom, RecordAttributes, TableType, InitFun), 
				changed 
	end.

delete_table(RecordAtom) -> mnesia:delete_table(RecordAtom).

create_table(RecordAtom, RecordAttributes, TableType, InitFun) ->
	mnesia:create_table(RecordAtom,
			[{attributes, 
				RecordAttributes },
				{type, TableType},
				{disc_copies, [node()]}]),

	transaction(InitFun).

start_tables(IsDistributionInit, RecordAtomList) ->
	start_tables(IsDistributionInit, RecordAtomList, false).

start_tables(IsDistributionInit, [RecordAtom|RAList], false = _IsSchemaChanged) ->
	StartResult = start_table(IsDistributionInit, RecordAtom),
	IsSchemaChanged = case StartResult of
		ok -> false;
		changed -> true end,
	start_tables(IsDistributionInit, RAList, IsSchemaChanged);
start_tables(IsDistributionInit, [RecordAtom|RAList], true = _IsSchemaChanged) ->
	start_table(IsDistributionInit, RecordAtom),
	start_tables(IsDistributionInit, RAList, true);
start_tables(_IsDistributionInit, [], false = _IsSchemaChanged) -> {ok, no_change};
start_tables(_IsDistributionInit, [], true = _IsSchemaChanged) -> {ok, schema_changed}.

%get_unique_id(TableName) ->
%	mnesia:dirty_update_counter(unique_ids, TableName, 1).

transaction(F) ->
	try {atomic, mnesia:activity(transaction, F)}
	catch
		_:Reason ->
			{aborted, Reason}
	end.

evaluate_query(Query) ->
	F = fun() -> handle_query(Query) end,
	Result = transaction(F),
	handle_result(Query, Result).

cache_lookup(Query) ->
	case ets:lookup(query_cache, Query) of
		[] -> miss;
		[I|_] -> {hit, I} end.

cache_insert(Query, Return) ->
	ets:insert(query_cache, {Query, Return}),
	ok.

cache_clean() -> 
	cache_clean0(),
	MnesiaNodes = get_mnesia_nodes(),
	case is_mnesia_distributed() of
		true -> mydlp_distributor:flush_cache(MnesiaNodes);
		false -> ok end,
	ok.

cache_clean0() ->
	ets:delete_all_objects(query_cache),
	ok.

cache_cleanup_handle() ->
	MaxSize = ?CFG(query_cache_maximum_size),
	case ets:info(query_cache, memory) of
		I when I > MaxSize -> cache_clean();
		_Else -> ok end.
	

call_timer() -> timer:send_after(5000, cleanup_now).
%call_timer() -> timer:send_after(?CFG(query_cache_cleanup_interval), cleanup_now).

-ifdef(__MYDLP_NETWORK).

ip_band({A1,B1,C1,D1}, {A2,B2,C2,D2}) -> {A1 band A2, B1 band B2, C1 band C2, D1 band D2}.

resolve_all(Rules) -> resolve_all(Rules, get_dcid()).

resolve_all(Rules, FilterId) ->
	Q = ?QLCQ([{F#filter.id, F#filter.default_action} || 
			F <- mnesia:table(filter),
			F#filter.id == FilterId
			]),
	case ?QLCE(Q) of
		[FilterKey] -> 	
			Rules1 = lists:usort(Rules),
			RRules = resolve_rules(Rules1),
			TextExtraction = predict_need4te(RRules),
			{{true}, FilterKey, RRules};
		_Else -> {{false}, {0, pass}, []} end.

predict_need4te([{_RId, _RAction, ITypes}|Rules]) ->
	case predict_need4te_1(ITypes) of
		true -> true;
		false -> predict_need4te(Rules) end;
predict_need4te([]) -> false.

predict_need4te_1([{_ITId, _Threshold, _DataFormats, IFeatures}|ITypes]) ->
	case predict_need4te_2(IFeatures) of
		true -> true;
		false -> predict_need4te_1(ITypes) end;
predict_need4te_1([]) -> false.

predict_need4te_2([{_Weight, {Func, _FuncParams}}|IFeatures]) ->
	case get_matcher_req(Func) of
                raw -> predict_need4te_2(IFeatures);
                analyzed -> true;
                text -> true end;
predict_need4te_2([]) -> false.

get_matcher_req(Func) -> apply(mydlp_matchers, Func, []).

resolve_rules(PS) -> resolve_rules(PS, []).
resolve_rules([{RId, ROrigId,RAction}|PS], Rules) -> 
	resolve_rules(PS, [{ROrigId, RAction, find_itypes(RId)}| Rules]);
resolve_rules([], Rules) -> lists:reverse(Rules).

find_itypes(RuleId) ->
	QM = ?QLCQ([{T#itype.orig_id, T#itype.threshold, 
			T#itype.data_formats, find_ifeatures(T#itype.id)} ||
			T <- mnesia:table(itype),
			T#itype.rule_id == RuleId
		]),
	?QLCE(QM).

find_ifeatures(ITypeId) ->
	QM = ?QLCQ([{F#ifeature.weight, find_func(F#ifeature.id)} ||
			F <- mnesia:table(ifeature),
			F#ifeature.itype_id == ITypeId
		]),
	?QLCE(QM).

find_func(IFeatureId) ->
	QM = ?QLCQ([{M#match.func, M#match.func_params} ||
			M <- mnesia:table(match),
			M#match.ifeature_id == IFeatureId
		]),
	case ?QLCE(QM) of
		[FuncTuple] -> FuncTuple;
		_Else -> throw({ierror, cannot_be_more_than_one_matcher}) end.

-endif.

consistency_chk() -> 
	compile_regex().

compile_regex() ->
	mnesia:wait_for_tables([regex], 5000),
	RegexC = fun() ->
		Q = ?QLCQ([R || R <- mnesia:table(regex),
			R#regex.plain /= undefined,
			R#regex.compiled == undefined,
			R#regex.error == undefined
			]),
		[mnesia:write(R) || R <- compile_regex(?QLCE(Q))]
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

% aqc(Query) -> aqc(Query, nocache).

aqc(Query, flush) -> async_query_call(Query, flush);
aqc(Query, cache) -> async_query_call(Query, cache);
aqc(Query, nocache) -> async_query_call(Query, nocache).

async_query_call(Query, CacheOption) -> 
	case gen_server:call(?MODULE, {async_query, CacheOption, Query}, 5000) of
		{ierror, {Class, Error}} -> mydlp_api:exception(Class, Error);
		Else -> Else end.

all_tab_names() -> tab_names1(?TABLES, []).

nondata_tab_names() -> tab_names1(?NONDATA_TABLES, []).

bayes_tab_names() -> tab_names1(?BAYES_TABLES, []).

%tab_names() -> tab_names1(?TABLES, [unique_ids]).

tab_names1([{Tab,_,_}|Tabs], Returns) -> tab_names1(Tabs, [Tab|Returns]);
tab_names1([{Tab,_}|Tabs], Returns) -> tab_names1(Tabs, [Tab|Returns]);
tab_names1([Tab|Tabs], Returns) when is_atom(Tab) ->  tab_names1(Tabs, [Tab|Returns]);
tab_names1([], Returns) -> lists:reverse(Returns).

-ifdef(__MYDLP_NETWORK).

%% File Group functions

add_file_group(FI, GI) ->
	Q = ?QLCQ([G#file_group.id ||	
		G <- mnesia:table(file_group),
		G#file_group.file_id == FI,
		G#file_group.group_id == GI 
		]),
	case ?QLCE(Q) of
		[] -> 	NewId = get_unique_id(file_hash),
			FG = #file_group{id=NewId, file_id=FI, group_id=GI},
			mnesia:write(FG);
		_Else -> ok end.

remove_filters(FIs) -> lists:foreach(fun(Id) -> remove_filter(Id) end, FIs), ok.

remove_filter(FI) ->
	Q = ?QLCQ([R#rule.id ||	
		R <- mnesia:table(rule),
		R#rule.filter_id == FI
		]),
	RIs = ?QLCE(Q),
	remove_rules(RIs),
	mnesia:delete({filter, FI}).

remove_rules(RIs) -> lists:foreach(fun(Id) -> remove_rule(Id) end, RIs), ok.

remove_rule(RI) ->
	Q1 = ?QLCQ([T#itype.data_formats ||	
		T <- mnesia:table(itype),
		T#itype.rule_id == RI
		]),
	DFIs = lists:flatten(?QLCE(Q1)),

	Q2 = ?QLCQ([T#itype.id ||	
		T <- mnesia:table(itype),
		T#itype.rule_id == RI
		]),
	ITIs = ?QLCE(Q2),

	remove_data_formats(DFIs),
	remove_itypes(ITIs),
	mnesia:delete({rule, RI}).

remove_data_formats(DFIs) -> lists:foreach(fun(Id) -> remove_data_format(Id) end, DFIs), ok.

remove_data_format(DFI) -> 
	Q1 = ?QLCQ([MT#mime_type.id ||	
		MT <- mnesia:table(mime_type),
		MT#mime_type.data_format_id == DFI
		]),
	MTIs = ?QLCE(Q1),

	remove_mime_types(MTIs).

remove_mime_types(MTIs) -> lists:foreach(fun(Id) -> remove_mime_type(Id) end, MTIs), ok.

remove_mime_type(MTI) -> mnesia:delete({mime_type, MTI}).

remove_itypes(ITIs) -> lists:foreach(fun(Id) -> remove_itype(Id) end, ITIs), ok.

remove_itype(ITI) ->
	Q = ?QLCQ([F#ifeature.id ||	
		F <- mnesia:table(ifeature),
		F#ifeature.itype_id == ITI
		]),
	IFIs = ?QLCE(Q),
	remove_ifeatures(IFIs),
	mnesia:delete({itype, ITI}).

remove_ifeatures(IFIs) -> lists:foreach(fun(Id) -> remove_ifeature(Id) end, IFIs), ok.

remove_ifeature(IFI) ->
	Q = ?QLCQ([M#match.id ||	
		M <- mnesia:table(match),
		M#match.ifeature_id == IFI
		]),
	MIs = ?QLCE(Q),
	remove_matches(MIs),
	mnesia:delete({ifeature, IFI}).

remove_matches(MIs) -> lists:foreach(fun(Id) -> remove_match(Id) end, MIs), ok.

remove_match(MI) -> mnesia:delete({match, MI}).

-endif.

