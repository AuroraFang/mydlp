%%%
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

-module(mydlp_acceptor).

-author('kerem@medratech.com').
-author('saleyn@gmail.com').

-behaviour(gen_server).

%% External API
-export([start_link/4,
	accept_loop/2]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-record(state, {listener,		% Listening socket
		socket_sup,				% Supervisor name for FSM handlers
		comm_type				% Whether socket is SSL or plain
	   }).

%%--------------------------------------------------------------------
%% @spec (AcceptorName, Port::integer(), CommType, SocketSup) -> {ok, Pid} | {error, Reason}
%
%% @doc Called by a supervisor to start the listening process.
%% @end
%%----------------------------------------------------------------------
start_link(AcceptorName, Port, CommType, SocketSup) when is_integer(Port) ->
	gen_server:start_link({local, AcceptorName}, ?MODULE, [Port, CommType, SocketSup], []).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%----------------------------------------------------------------------
%% @spec (Port::integer()) -> {ok, State}		   |
%%							{ok, State, Timeout}  |
%%							ignore				|
%%							{stop, Reason}
%%
%% @doc Called by gen_server framework at process startup.
%%	  Create listening socket.
%% @end
%%----------------------------------------------------------------------
init([Port, CommType, SocketSup]) ->
	process_flag(trap_exit, true),
	Opts = [binary, {packet, 0}, {reuseaddr, true}, {nodelay, true},
			{keepalive, true}, {backlog, 30}, {active, false}],
	
	{Backend, Opts1} = case CommType of
			plain -> {gen_tcp, Opts};
			ssl -> 
				{ok, SslFiles} = application:get_env(ssl_files),
				{ssl, Opts ++ [{ssl_imp, new}, {verify, 0}] ++ SslFiles}
		end,

	case Backend:listen(Port, Opts1) of
		{ok, ListSock} ->
			%%Create first accepting process
			State = #state{listener = ListSock,
						socket_sup = SocketSup,
						comm_type = CommType},
			{ok, accept(State)};
		{error, Reason} ->
			{stop, Reason}
	end.

%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}		  |
%%								 {reply, Reply, State, Timeout} |
%%								 {noreply, State}			   |
%%								 {noreply, State, Timeout}	  |
%%								 {stop, Reason, Reply, State}   |
%%								 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%	  is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_call(Request, _From, State) ->
	{stop, {unknown_call, Request}, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}		  |
%%					  {noreply, State, Timeout} |
%%					  {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%	  is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_cast(accepted, State) ->
	{noreply, accept(State)};

handle_cast(_Msg, State) ->
	{noreply, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}		  |
%%					  {noreply, State, Timeout} |
%%					  {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%	  If `{stop, ...}' tuple is returned, the server is stopped and
%%	  `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_info(_Info, State) ->
	{noreply, State}.

%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%	   `process_flag(trap_exit, true)' is set by the server process.
%%	   The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, #state{comm_type=CommType} = State) ->
	Backend = case CommType of
		plain -> gen_tcp;
		ssl -> ssl
	end,
	Backend:close(State#state.listener),
	ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%------------------------------------------------------------------------
%%% Internal functions
%%%------------------------------------------------------------------------

%% Taken from prim_inet.  We are merely copying some socket options from the
%% listening socket to the new client socket.
set_sockopt(ListSock, CliSocket, CommType) ->
	true = case CommType of
			plain -> inet_db:register_socket(CliSocket, inet_tcp);
			ssl -> true
		end,

	{Backend,BackendClose,Opts} = case CommType of
			plain -> {prim_inet, gen_tcp,
					[active, nodelay, keepalive, 
					delay_send, priority, tos]};
			ssl -> {ssl, ssl, [active]}
		end,

	case Backend:getopts(ListSock, Opts) of
		{ok, Opts1} ->
			case Backend:setopts(CliSocket, Opts1) of
				ok	-> ok;
				Error -> BackendClose:close(CliSocket), Error
			end;
		Error ->
			BackendClose:close(CliSocket), Error
	end.

do_accept(_State=#state{listener=ListSock, 
		comm_type=CommType}) ->
	case CommType of
		plain -> gen_tcp:accept(ListSock);
		ssl -> case ssl:transport_accept(ListSock) of
				{ok, SSLSocket} -> case ssl:ssl_accept(SSLSocket) of
						ok -> {ok, SSLSocket};
						Else -> Else
					end;
				Else -> Else
			end
	end.

accept_loop(Acceptor, 
		State=#state{listener=ListSock, 
			comm_type=CommType, 
			socket_sup=SocketSup}) ->

	Backend = case CommType of 
			plain -> gen_tcp;
			ssl -> ssl
		end,

	Return = case do_accept(State) of
		{ok, CliSocket} ->
			case set_sockopt(ListSock, CliSocket, CommType) of
				ok	  -> 
					%% New client connected - spawn a new process using the simple_one_for_one
					%% supervisor.
					{ok, Pid} = mydlp_sup:start_client(SocketSup),
					Backend:controlling_process(CliSocket, Pid),
					%% Instruct the new FSM that it owns the socket.
					mydlp_fsm:set_socket(Pid, CliSocket, CommType),
					ok;
				{error, Reason} -> {error, {set_sockopt, Reason}}
			end;
		{error, Reason} -> {error, {do_accept, Reason}}
	end,
	%% Signal the acceptor that we are ready to accept another connection
	gen_server:cast(Acceptor, accepted),

	case Return of
		{error, Reason1} -> exit(Reason1);
		Else -> Else
	end.
	
accept(State) ->
	proc_lib:spawn(?MODULE, accept_loop, [self(), State]),
	State.
