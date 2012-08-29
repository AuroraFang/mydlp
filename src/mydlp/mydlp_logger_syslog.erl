%%%
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

-module(mydlp_logger_syslog).
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
	syslog_acl_fd,
	syslog_diag_fd,
	syslog_report_fd
}).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_event
%%%----------------------------------------------------------------------

%%---------------------------------------------------------------------
%% Socket definitions
%%---------------------------------------------------------------------
start_socket(Tag, RHost, RPort, Fac, Level) ->
	case gen_udp:open(0) of
		{ok, Fd} ->
			syslog({Fd, RHost, RPort}, Fac, Level, "MyDLP " ++ Tag ++ " logger started"),
			{ok, Fd};
		{error, Reason} -> {error, Reason}
	end.
	    
%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          Other
%%----------------------------------------------------------------------
init(_) -> init().
init() ->
	AclHost = {127,0,0,1},
	AclPort = 514,
	DiagHost = {127,0,0,1},
	DiagPort = 514,
	AclFac = ?FAC_LOCAL6,
	DiagFac = ?FAC_LOCAL6,
	ReportHost = {127,0,0,1},
	ReportPort = 514,
	ReportFac = ?FAC_LOCAL7,
	{ok, AclFd} = start_socket("ACL", AclHost, AclPort, AclFac, ?LOG_INFO),
	{ok, DiagFd} = start_socket("Diagnostic", DiagHost, DiagPort, DiagFac, ?LOG_DEBUG),
	{ok, ReportFd} = start_socket("Report", ReportHost, ReportPort, ReportFac, ?LOG_INFO),
	{ok, #state{syslog_acl_fd=AclFd, syslog_diag_fd=DiagFd, syslog_report_fd=ReportFd}}.

%%----------------------------------------------------------------------
%% Func: handle_event/2
%% Returns: {ok, State}                                |
%%          {swap_handler, Args1, State1, Mod2, Args2} |
%%          remove_handler                              
%%----------------------------------------------------------------------
handle_event({ReportLevel, _, {FromPid, StdType, Report}}, State) when is_record(Report, report), is_atom(StdType) ->
	RL = case {ReportLevel,StdType} of
		{error_report, _} -> ?LOG_ERROR;
		{warning_report, _} -> ?LOG_WARNING;
		{info_report, _} -> ?LOG_INFO
	end,
	syslog_report(State,  RL,  io_lib:format ("~p: " ++ Report#report.format, [FromPid|Report#report.data])),
	{ok, State};

handle_event({ReportLevel, _, {_FromPid, StdType, Report}}, State) when is_atom(StdType) ->
	RL = case {ReportLevel,StdType} of
		{error_report, _} -> ?LOG_ERROR;
		{warning_report, _} -> ?LOG_WARNING;
		{info_report, _} -> ?LOG_INFO
	end,
	syslog_report(State,  RL, io_lib:format ("~p", [Report])),
	{ok, State};

handle_event({EventLevel, _, {_FromPid, Fmt, Data}}, State) ->
	Message = io_lib:format (Fmt, Data),
	case EventLevel of
		error -> syslog_err(State, Message);
		warning_msg -> syslog_syswarn(State, Message);
		info_msg -> syslog_debug(State, Message);
		acl_msg -> syslog_acl(State, Message);
		smtp -> syslog_smtp(State, Message);
		_Else -> ok
	end,
	{ok, State};

handle_event(Event, State) ->
	syslog_syswarn(State, io_lib:format ("Unknown event [~p]", [Event])),
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
	syslog_misc(State, io_lib:format ("Info [~p]", [Info])),
	{ok, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any
%%----------------------------------------------------------------------
terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%%%%%%%%%%%%% Internal

syslog({Fd, Host, Port}, Facility, Level, Message) ->
	M = list_to_binary([Message]),
	P = list_to_binary(integer_to_list(Facility bor Level)),
	gen_udp:send(Fd, Host, Port, <<"<", P/binary, ">", M/binary, "\n">>).

syslog_acl(#state{syslog_acl_fd=AclFd}, Message) ->
	AclHost = {127,0,0,1},
	AclPort = 514,
	AclFac = ?FAC_LOCAL6,
	syslog({AclFd, AclHost, AclPort}, AclFac, ?LOG_INFO, Message).

syslog_diag(#state{syslog_diag_fd=DiagFd}, Level, Message) ->
	DiagHost = {127,0,0,1},
	DiagPort = 514,
	DiagFac = ?FAC_LOCAL6,
	syslog({DiagFd, DiagHost, DiagPort}, DiagFac, Level, Message).

syslog_report(#state{syslog_report_fd=ReportFd}, Level, Message) ->
	ReportHost = {127,0,0,1},
	ReportPort = 514,
	ReportFac = ?FAC_LOCAL7,
	syslog({ReportFd, ReportHost, ReportPort}, ReportFac, Level, ["[MyDLP Report] " | [Message] ]).
	
syslog_err(State, Message) -> syslog_diag(State, ?LOG_ERROR, Message).

syslog_debug(State, Tag, Message) -> syslog_diag(State, ?LOG_DEBUG, ["[MyDLP ", Tag, "] " | [Message] ]).

syslog_smtp(State, Message) -> syslog_debug(State, "SMTP", Message).

syslog_misc(State, Message) -> syslog_debug(State, "Misc", Message).

syslog_debug(State, Message) -> syslog_debug(State, "Debug", Message).

syslog_syswarn(State, Message) -> syslog_debug(State, "SysWarn", Message).


