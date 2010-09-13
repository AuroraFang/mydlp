%%
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
%%% @copyright 2009, H. Kerem Cevahir
%%% @doc Worker for mydlp.
%%% @end
%%%-------------------------------------------------------------------
-module(mydlp_tc).
-author("kerem@medra.com.tr").
-behaviour(gen_server).

-include("mydlp.hrl").

%% API
-export([start_link/0,
	get_mime/1,
	is_valid_iban/1,
	html_to_text/1,
	stop/0]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {backend_py}).

%%%%%%%%%%%%% MyDLP Thrift RPC API

-define(MMLEN, 4096).

get_mime(Data) when is_list(Data) ->
	L = length(Data),
	Data1 = case L > ?MMLEN of
		true -> lists:sublist(Data, ?MMLEN);
		false -> Data
	end,
	call_pool({thrift, py, getMagicMime, [Data1]});

get_mime(Data) when is_binary(Data) ->
	S = size(Data),
	Data1 = case S > ?MMLEN of
		true -> <<D:?MMLEN/binary, _/binary>> = Data, D;
		false -> Data
	end,
	call_pool({thrift, py, getMagicMime, [Data1]}).

is_valid_iban(IbanStr) ->
	call_pool({thrift, py, isValidIban, [IbanStr]}).

html_to_text(Html) ->
	call_pool({thrift, py, htmlToText, [Html]}).

%%%%%%%%%%%%%% gen_server handles

handle_call({thrift, py, Func, Params}, _From, #state{backend_py=TS} = State) ->
	{TS1, {ok, Reply}} = thrift_client:call(TS, Func, Params),
	{reply, Reply, State#state{backend_py=TS1}, 15000};

handle_call(stop, _From, #state{backend_py=PY} = State) ->
	thrift_client:close(PY),
	{stop, normalStop, State#state{backend_py=undefined}};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_info({async_thrift, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info(_Info, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%% Implicit functions

start_link() ->
	ConfList = case application:get_env(thrift) of
                {ok, CL} -> CL;
                _Else -> ?THRIFTCONF
        end,

	{client_pool_size, CPS} = lists:keyfind(client_pool_size, 1, ConfList),

	PL = [ gen_server:start_link(?MODULE, [], []) || _I <- lists:seq(1, CPS)],
	pg2:create(?MODULE),
	[pg2:join(?MODULE, P) || {ok, P} <- PL],

	ignore.

stop() ->
	gen_server:call(?MODULE, stop).

init([]) ->
	{ok, PY} = thrift_client_util:new("localhost",9090, mydlp_thrift, []),
	{ok, #state{backend_py=PY}}.

handle_cast(_Msg, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

call_pool(Req) ->
	Pid = pg2:get_closest_pid(?MODULE),
	gen_server:call(Pid, Req).
