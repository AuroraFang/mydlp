%%
%%%    Copyright (C) 2012 Huseyin Kerem Cevahir <kerem@mydlp.com>
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

-ifdef(__MYDLP_ENDPOINT).

-module(mydlp_logger_file).
-author('kerem@mydlp.com').

-behaviour(gen_event).

-include("mydlp.hrl").

%% gen_event callbacks
-export([
	init/1,
	handle_event/2,
	handle_call/2,
	handle_info/2,
	terminate/2,
	code_change/3
]).

-export([
%	test/0
]).

-record(state, {
	acl_fd,
	error_fd,
	report_fd
}).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_event
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          Other
%%----------------------------------------------------------------------
init(_) -> init().
init() ->
	LogDir = ?CFG(log_dir),
	{ok, AclFd} = fopen(LogDir ++ "/acl.log"),
	{ok, ErrorFd} = fopen(LogDir ++ "/error.log"),
	{ok, ReportFd} = fopen(LogDir ++ "/report.log"),
	{ok, #state{acl_fd=AclFd, error_fd=ErrorFd, report_fd=ReportFd}}.

%%----------------------------------------------------------------------
%% Func: handle_event/2
%% Returns: {ok, State}                                |
%%          {swap_handler, Args1, State1, Mod2, Args2} |
%%          remove_handler                              
%%----------------------------------------------------------------------
handle_event({_ReportLevel, _, {FromPid, StdType, Report}}, State) when is_record(Report, report), is_atom(StdType) ->
	try	filelog_report(State, io_lib:format ("~p: " ++ Report#report.format, [FromPid|Report#report.data]))
	catch Class:Error ->
                        ?ERROR_LOG("Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~n",
                        [Class, Error, erlang:get_stacktrace()]) end,
	{ok, State};

handle_event({_ReportLevel, _, {_FromPid, StdType, Report}}, State) when is_atom(StdType) ->
	try	filelog_report(State, io_lib:format ("~p", [Report]))
	catch Class:Error ->
                        ?ERROR_LOG("Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~n",
                        [Class, Error, erlang:get_stacktrace()]) end,
	{ok, State};

handle_event({EventLevel, _, {_FromPid, Fmt, Data}}, State) ->
	try	Message = io_lib:format (Fmt, Data),
		case EventLevel of
			error -> filelog_err(State, Message);
			acl_msg -> filelog_acl(State, Message);
			_Else -> ok
		end
	catch Class:Error ->
                        ?ERROR_LOG("Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~n",
                        [Class, Error, erlang:get_stacktrace()]) end,
	{ok, State};

handle_event(Event, State) ->
	try	filelog_err(State, io_lib:format ("Unknown event [~p]", [Event]))
	catch Class:Error ->
                        ?ERROR_LOG("Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~n",
                        [Class, Error, erlang:get_stacktrace()]) end,
	{ok, State}.

%%----------------------------------------------------------------------
%% Func: handle_call/2
%% Returns: {ok, Reply, State}                                |
%%          {swap_handler, Reply, Args1, State1, Mod2, Args2} |
%%          {remove_handler, Reply}                            
%%----------------------------------------------------------------------
handle_call(_Request, State) ->
	Reply = ok,
	{ok, Reply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {ok, State}                                |
%%          {swap_handler, Args1, State1, Mod2, Args2} |
%%          remove_handler                              
%%----------------------------------------------------------------------
handle_info(Info, State) ->
	try	filelog_err(State, io_lib:format ("Info [~p]", [Info]))
	catch Class:Error ->
                        ?ERROR_LOG("Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~n",
                        [Class, Error, erlang:get_stacktrace()]) end,
	{ok, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any
%%----------------------------------------------------------------------
terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%%%%%%%%%%%%% Internal

write_time() ->
	{{Y,Mo,D},{H,Mi,S}} = erlang:localtime(),
	io_lib:format("~w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w -> ", [Y, Mo, D, H, Mi, S]).

filelog(Fd, Message) ->
	Time = write_time(),
	M = list_to_binary([Time, Message]),
	HeadLen = size(M) - 1,
	M1 = case M of
		<<_Head:HeadLen/binary, "\n" >> -> M;
		_Else -> <<M/binary, "\n">> end,
	file:write(Fd, M1).

filelog_acl(#state{acl_fd=AclFd}, Message) ->
	filelog(AclFd, Message).

filelog_err(#state{error_fd=ErrorFd}, Message) ->
	filelog(ErrorFd, Message).

filelog_report(#state{report_fd=ReportFd}, Message) ->
	filelog(ReportFd, Message).
	
fopen(Filename) -> file:open(Filename, [append, raw]).

-endif.

