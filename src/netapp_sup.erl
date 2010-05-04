-module(netapp_sup).

-author('kerem@medratech.com').
-author('saleyn@gmail.com').

-behaviour(supervisor).

%% Internal API
-export([start_client/1]).

%% Application and Supervisor callbacks
-export([init/1]).

-include("netapp.hrl").

%% A startup function for spawning new client connection handling FSM.
%% To be called by the TCP listener process.
start_client(SocketSup) ->
	supervisor:start_child(SocketSup, []).

%%----------------------------------------------------------------------
%% Supervisor behaviour callbacks
%%----------------------------------------------------------------------
init([protocol_supervisor, ProtoConf]) ->
	{	Proto,
		{acceptor, {Port, CommType, FsmModule}}, 
		{workers, Workers}
	} = ProtoConf,

	AcceptorName = list_to_atom(atom_to_list(Proto) ++ "_acceptor"),
	AcceptorSupName = list_to_atom(atom_to_list(Proto) ++ "_acceptor_sup"),
	WorkerSupName = list_to_atom(atom_to_list(Proto) ++ "_worker_sup"),
	SocketSupName = list_to_atom(atom_to_list(Proto) ++ "_socket_sup"),

	{ok,
		{_SupFlags = {one_for_one, ?MAX_RESTART, ?MAX_TIME},
			[
				% TCP Listener
			  {   AcceptorSupName,							% Id	   = internal id
				  {netapp_acceptor, start_link,
				  	[AcceptorName, Port, CommType, SocketSupName]
				  },										% StartFun = {M, F, A}
				  permanent,								% Restart  = permanent | transient | temporary
				  ?KILL_TIMEOUT,							% Shutdown = brutal_kill | int() >= 0 | infinity
				  worker,									% Type	 = worker | supervisor
				  [netapp_acceptor]							% Modules  = [Module] | dynamic
			  },
				% Worker supervisor
			  {   WorkerSupName,							% Id	   = internal id
				  {supervisor, start_link,
				  	[{local, WorkerSupName}, netapp_worker_sup, [Workers]]
				  },										% StartFun = {M, F, A}
				  permanent,								% Restart  = permanent | transient | temporary
				  infinity,									% Shutdown = brutal_kill | int() >= 0 | infinity
				  supervisor,								% Type	 = worker | supervisor
				  [netapp_worker_sup]						% Modules  = [Module] | dynamic
			  },
				% Client instance supervisor
			  {   SocketSupName,							% Id       = internal id
				  {supervisor,start_link,[{local, SocketSupName}, ?MODULE, [socket, FsmModule]]},
				  permanent,								% Restart  = permanent | transient | temporary
				  infinity,									% Shutdown = brutal_kill | int() >= 0 | infinity
				  supervisor,								% Type	 = worker | supervisor
				  []										% Modules  = [Module] | dynamic
			  }
			]
		}
	};

init([socket, FsmModule]) ->
	{ok,
		{_SupFlags = {simple_one_for_one, ?MAX_RESTART, ?MAX_TIME},
			[
				% TCP Client
			  {   undefined,								% Id	   = internal id
				  {netapp_fsm,start_link,[FsmModule]},		% StartFun = {M, F, A}
				  temporary,								% Restart  = permanent | transient | temporary
				  ?KILL_TIMEOUT,							% Shutdown = brutal_kill | int() >= 0 | infinity
				  worker,									% Type	 = worker | supervisor
				  []										% Modules  = [Module] | dynamic
			  }
			]
		}
	}.

