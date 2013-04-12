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

-module(mydlp_seap_fsm).
-author('kerem@mydlp.com').
-behaviour(gen_fsm).
-include("mydlp.hrl").

-export([start_link/0]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

%% FSM States
-export([
    'WAIT_FOR_SOCKET'/2,
    'SEAP_REQ'/2,
    'PUSH_DATA_RECV'/2,
    'TRAP_WAIT'/2
]).

-record(state, {
	socket,
	addr,
	obj_id,
	recv_size,
	recv_data=[],
	trap_timer
}).

-define(BIN_OK, <<"OK">>).
-define(BIN_ERR, <<"ERR">>).

%%%------------------------------------------------------------------------
%%% API
%%%------------------------------------------------------------------------

start_link() ->
	gen_fsm:start_link(?MODULE, [], []).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%% @private
%%-------------------------------------------------------------------------
init([]) ->
	process_flag(trap_exit, true),
	{ok, 'WAIT_FOR_SOCKET', #state{}}.

%%-------------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
'WAIT_FOR_SOCKET'({socket_ready, Socket, _CommType}, State) when is_port(Socket) ->
	inet:setopts(Socket, [{active, once}, {nodelay, true}, {packet, line}, list]),
	{ok, {IP, _Port}} = inet:peername(Socket),
	{next_state, 'SEAP_REQ', State#state{socket=Socket, addr=IP}, ?CFG(fsm_timeout)};
'WAIT_FOR_SOCKET'(Other, State) ->
	?DEBUG("SEAP FSM: 'WAIT_FOR_SOCKET'. Unexpected message: "?S, [Other]),
	%% Allow to receive async messages
	{next_state, 'WAIT_FOR_SOCKET', State}.

%% Notification event coming from client
'SEAP_REQ'({data, "BEGIN" ++ _Else}, State) -> 
	'BEGIN_RESP'(State);
'SEAP_REQ'({data, "SETPROP" ++ Rest}, State) -> 
	{ ObjId, Key, Value } = get_setprop_args(Rest),
	'SETPROP_RESP'(State, ObjId, Key, Value);
'SEAP_REQ'({data, "GETPROP" ++ Rest}, State) -> 
	{ ObjId, Key } = get_getprop_args(Rest),
	'GETPROP_RESP'(State, ObjId, Key);
'SEAP_REQ'({data, "PUSHFILE" ++ Rest}, State) -> 
	{ ObjId, FilePath } = get_getprop_args(Rest),
	'PUSHFILE_RESP'(State, ObjId, FilePath);
'SEAP_REQ'({data, "PUSHCHUNK" ++ Rest}, State) -> 
	{ ObjId, ChunkPath } = get_getprop_args(Rest),
	'PUSHCHUNK_RESP'(State, ObjId, ChunkPath);
'SEAP_REQ'({data, "PUSH" ++ Rest}, #state{socket=Socket} = State) -> 
	{ ObjId, RecvSize} = get_req_args(Rest),
	inet:setopts(Socket, [{active, once}, {packet, 0}, binary]),
	{next_state, 'PUSH_DATA_RECV', State#state{obj_id=ObjId, recv_size=RecvSize}, ?CFG(fsm_timeout)};
'SEAP_REQ'({data, "END" ++ Rest}, State) -> 
	{ ObjId } = get_req_args(Rest),
	'END_RESP'(State, ObjId);
'SEAP_REQ'({data, "ACLQ" ++ Rest}, State) -> 
	{ ObjId } = get_req_args(Rest),
	'ACLQ_RESP'(State, ObjId);
'SEAP_REQ'({data, "DESTROY" ++ Rest}, State) -> 
	{ ObjId } = get_req_args(Rest),
	'DESTROY_RESP'(State, ObjId);
'SEAP_REQ'({data, "CONFUPDATE" ++ Rest}, State) -> 
	MetaDict = get_map_args(Rest),
	'CONFUPDATE_RESP'(State, MetaDict);
'SEAP_REQ'({data, "GETKEY" ++ _Rest}, State) -> 
	'GETKEY_RESP'(State);
'SEAP_REQ'({data, "HASKEY" ++ _Rest}, State) -> 
	'HASKEY_RESP'(State);
'SEAP_REQ'({data, "IECP" ++ Rest}, State) -> 
	{IpAddr, FP, D} = get_iecp_args(Rest),
	'IECP_RESP'(State, IpAddr, FP, D);
'SEAP_REQ'({data, "TRAP" ++ _Rest}, State) -> 
	mydlp_container:set_trap_pid(self()),
	State1 = start_timer(State),
	{next_state, 'TRAP_WAIT', State1, 60000 + ?CFG(fsm_timeout)};
'SEAP_REQ'({data, "HELP" ++ _Rest}, State) -> 
	'HELP_RESP'(State);
'SEAP_REQ'({data, _Else}, State) -> 
	'HELP_RESP'(State);
'SEAP_REQ'(timeout, State) ->
	?DEBUG(?S" Client connection timeout - closing.\n", [self()]),
	{stop, normal, State}.

'BEGIN_RESP'(State) ->
	{ok, ObjId} = mydlp_container:new(),
	send_ok(State, ObjId),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'SETPROP_RESP'(State, ObjId, Key, Value) ->
	ok = mydlp_container:setprop(ObjId, Key, Value),
	send_ok(State),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'GETPROP_RESP'(State, ObjId, Key) ->
	{ok, Value} = mydlp_container:getprop(ObjId, Key),
	send_ok(State, Value),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'PUSH_RESP'(State, ObjId, ObjData) ->
	ok = mydlp_container:push(ObjId, ObjData),
	send_ok(State),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'PUSHFILE_RESP'(State, ObjId, FilePath) ->
	ok = mydlp_container:pushfile(ObjId, FilePath),
	send_ok(State),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'PUSHCHUNK_RESP'(State, ObjId, ChunkPath) ->
	ok = mydlp_container:pushchunk(ObjId, ChunkPath),
	send_ok(State),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'END_RESP'(State, ObjId) ->
	ok = mydlp_container:eof(ObjId),
	send_ok(State),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'ACLQ_RESP'(State, ObjId) ->
	{ok, Action} = mydlp_container:aclq(ObjId),
	send_ok(State, Action),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'DESTROY_RESP'(State, ObjId) ->
	ok = mydlp_container:destroy(ObjId),
	send_ok(State),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'CONFUPDATE_RESP'(State, MetaDict) ->
	mydlp_container:set_ep_meta_from_dict(MetaDict),
	Reply = case mydlp_container:confupdate() of
		true -> "yes";
		false -> "no" end,
	send_ok(State, Reply),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'HASKEY_RESP'(State) ->
	Reply = case ( catch mydlp_sync:get_enc_key() ) of
		Key when is_binary(Key), size(Key) == 64 -> "yes";
		_Else -> "no" end,
	send_ok(State, Reply),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'GETKEY_RESP'(State) ->
	case ( catch mydlp_sync:get_enc_key() ) of
		Key when is_binary(Key), size(Key) == 64 -> 
			{ok, KeyPath} = mydlp_api:write_to_tmpfile(Key),
			send_ok(State, KeyPath);
		_Else -> send_err(State) end,
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'IECP_RESP'(State, IpAddr, FilePath, PropDict) ->
	mydlp_api:iecp_command(IpAddr, FilePath, PropDict),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'HELP_RESP'(State) ->
	Print = "\r\n" ++ "Commands:" ++ "\r\n" ++
		"\t" ++ "BEGIN -> OK Id" ++ "\r\n" ++
		"\t" ++ "SETPROP Id Key=Value-> OK" ++ "\r\n" ++
		"\t" ++ "GETPROP Id Key-> OK Value" ++ "\r\n" ++
		"\t" ++ "PUSH Id ChunkSize" ++ "\r\n" ++
		"\t\t" ++ "Chunk -> OK" ++ "\r\n" ++
		"\t" ++ "PUSHFILE Id FilePath" ++ "\r\n" ++
		"\t" ++ "PUSHCHUNK Id ChunkPath" ++ "\r\n" ++
		"\t" ++ "END Id -> OK" ++ "\r\n" ++
		"\t" ++ "ACLQ Id -> OK Action" ++ "\r\n" ++
		"\t" ++ "DESTROY Id -> OK" ++ "\r\n" ++
		"\t" ++ "HELP -> This screen" ++ "\r\n" ++
		"Any other command prints this screen." ++ "\r\n" ++
		"If an internal error occurs, server respond with ERR instead of OK." ++ "\r\n",
	send_ok(State, Print),
	{next_state, 'SEAP_REQ', State, ?CFG(fsm_timeout)}.

'PUSH_DATA_RECV'({data, Data}, #state{socket=Socket, obj_id=ObjId, recv_size=RecvSize, recv_data=RecvData} = State) -> 
	DataSize = mydlp_api:binary_size(Data),
	NewSize = RecvSize - DataSize,
	case NewSize of
		-2 ->	case Data of
				<<DataC:RecvSize/binary, "\r\n">> -> 'PUSH_DATA_RECV'({data, DataC}, State);
				Else -> throw({error, {unexpected_binary_size, Else}}) end;
		0 -> 	RecvData1 = [Data|RecvData],
			ObjData = list_to_binary(lists:reverse(RecvData1)),
			inet:setopts(Socket, [{active, once}, {packet, line}, list]),
			'PUSH_RESP'(State#state{obj_id=undefined, recv_size=undefined, recv_data=[]}, ObjId, ObjData);
		NewSize when NewSize > 0 ->
			RecvData1 = [Data|RecvData],
			{next_state, 'PUSH_DATA_RECV', State#state{recv_size=NewSize, recv_data=RecvData1}, ?CFG(fsm_timeout)};
		_Else -> throw({error, {unexpected_binary_size, DataSize}}) end;
'PUSH_DATA_RECV'(timeout, State) ->
	?DEBUG(?S" Client connection timeout - closing.\n", [self()]),
	{stop, normal, State}.

'TRAP_WAIT'({data, _Data}, State) -> 
	{next_state, 'TRAP_WAIT', State, 60000 + ?CFG(fsm_timeout)};
'TRAP_WAIT'(timeout, State) ->
	?DEBUG(?S" Client connection timeout - closing.\n", [self()]),
	{stop, normal, State}.

%%-------------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_event(stop, _StateName, State) ->
	{stop, normal, State};
handle_event(Event, StateName, StateData) ->
	{stop, {StateName, undefined_event, Event}, StateData}.

%%-------------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_sync_event(Event, _From, StateName, StateData) ->
	{stop, {StateName, undefined_event, Event}, StateData}.

%%-------------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_info({tcp, Socket, Bin}, StateName, #state{socket=Socket} = StateData) ->
	% Flow control: enable forwarding of next TCP message
	Return = fsm_call(StateName, {data, Bin}, StateData),
	inet:setopts(Socket, [{active, once}]),
	Return;

handle_info({tcp_closed, Socket}, _StateName, #state{socket=Socket, addr=_Addr} = StateData) ->
	% ?ERROR_LOG(?S" Client "?S" disconnected.\n", [self(), Addr]),
	{stop, normal, StateData};

handle_info(trap_timeout, 'TRAP_WAIT', State) -> 
	mydlp_container:reset_trap_pid(),
	send_ok(State, "retrap"),
	State1 = cancel_timer(State),
	{next_state, 'SEAP_REQ', State1, ?CFG(fsm_timeout)};

handle_info({trap_message, Message}, 'TRAP_WAIT', State) -> 
	send_ok(State, Message),
	State1 = start_timer(State),
	{next_state, 'TRAP_WAIT', State1, 60000 + ?CFG(fsm_timeout)};

handle_info(Info, StateName, StateData) ->
	?ERROR_LOG("SEAP: Unexpected message: "?S"~nStateName: "?S", StateData: "?S, [Info, StateName, StateData]),
	{next_state, StateName, StateData}.

fsm_call(StateName, Args, StateData) -> 
	try ?MODULE:StateName(Args, StateData)
	catch Class:Error ->
		?ERROR_LOG("Error occured on FSM ("?S") call ("?S"). Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~n",
				[?MODULE, StateName, Class, Error, erlang:get_stacktrace()]),
		send_err(StateData),
		{next_state, 'SEAP_REQ', StateData, ?CFG(fsm_timeout)} end.

%%-------------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, _StateName, #state{socket=Socket} = _State) ->
	% @todo: close conenctions to message store
    (catch gen_tcp:close(Socket)),
    ok.

%%-------------------------------------------------------------------------
%% Func: code_change/4
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState, NewStateData}
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

get_req_args(Rest) ->
	Rest1 = mydlp_api:rm_trailing_crlf(Rest),
	case string:tokens(Rest1, " ") of
		[ObjIdS] -> { list_to_integer(ObjIdS) };
		[ObjIdS, ChunkSize] -> { list_to_integer(ObjIdS), list_to_integer(ChunkSize) };
		_Else -> throw({error, {obj_id_not_found, Rest}}) end.

%get_arg_str(Rest) ->
%	Rest1 = mydlp_api:rm_trailing_crlf(Rest),
%	ArgStr = string:strip(Rest1),
%	{ArgStr}.

get_setprop_args(Rest) ->
	Rest1 = mydlp_api:rm_trailing_crlf(Rest),
	Rest2 = string:strip(Rest1),
	{ObjIdS, KeyValuePairS} = case string:chr(Rest2, $\s) of
		0 -> throw({no_space_to_tokenize, Rest2});
		I -> OS = string:sub_string(Rest2, 1, I - 1),
			KVS = string:sub_string(Rest2, I + 1),
			{OS, KVS} end,
	KeyValuePairS2 = string:strip(KeyValuePairS),
	{Key, Value} = case string:chr(KeyValuePairS2, $=) of
		0 -> throw({no_equal_sign_to_tokenize, KeyValuePairS2});
		I2 -> KS = string:sub_string(KeyValuePairS2, 1, I2 - 1),
			VS = string:sub_string(KeyValuePairS2, I2 + 1),
			{KS, VS} end,
	{list_to_integer(ObjIdS), Key, Value}.

get_two_args(String) ->
	Rest1 = mydlp_api:rm_trailing_crlf(String),
	Rest2 = string:strip(Rest1),
	{S1, S2} = case string:chr(Rest2, $\s) of
		0 -> throw({no_space_to_tokenize, Rest2});
		I -> OS = string:sub_string(Rest2, 1, I - 1),
			KS = string:sub_string(Rest2, I + 1),
			{OS, KS} end,
	{S1, string:strip(S2)}.

get_getprop_args(Rest) ->
	{ObjIdS, Key} = get_two_args(Rest),
	{list_to_integer(ObjIdS), Key}.


get_map_args(Rest) -> 
	Rest1 = mydlp_api:rm_trailing_crlf(Rest),
	get_map_args1(Rest1).

get_map_args1(Rest1) -> 
	Tokens = string:tokens(Rest1, " "),
	get_map_args(Tokens, dict:new()).

get_map_args([Token|RestOfTokens], D) ->
	{Key, QpEncodedValue} = case string:chr(Token, $=) of
		0 -> throw({no_equal_sign_to_tokenize, Token});
		I -> KS = string:sub_string(Token, 1, I - 1),
			VS = string:sub_string(Token, I + 1),
			{KS, VS} end,
	D1 = dict:store(Key, QpEncodedValue, D),
	get_map_args(RestOfTokens, D1);
get_map_args([], D) -> D.

get_iecp_args(String) ->
	Rest1 = mydlp_api:rm_trailing_crlf(String),
	Rest2 = string:strip(Rest1),
	case string:chr(Rest2, $\s) of
		0 -> throw({no_space_to_tokenize, Rest2});
		I -> 	IpAddrS = string:sub_string(Rest2, 1, I - 1),
			Rest3 = string:sub_string(Rest2, I + 1),
			Rest4 = string:strip(Rest3),
			{FP, ArgStr} = case string:chr(Rest4, $\s) of
				0 -> throw({no_space_to_tokenize, Rest4});
				I2 -> 	CS = string:sub_string(Rest4, 1, I2 - 1),
					AS = string:sub_string(Rest4, I2 + 1),
					{CS, string:strip(AS)} end,
			IpAddr = mydlp_api:str_to_ip(IpAddrS),
			{IpAddr, mydlp_api:qp_decode(FP), get_map_args1(ArgStr)} end.

send(#state{socket=Socket}, Data) -> gen_tcp:send(Socket, <<Data/binary, "\r\n">>).

send_err(State) -> send(State, ?BIN_ERR).

send_ok(State) -> send(State, ?BIN_OK).

send_ok(State, Arg) when is_binary(Arg) -> send(State, <<?BIN_OK/binary, " ", Arg/binary>>);
send_ok(State, Arg) when is_integer(Arg) -> send_ok(State, integer_to_list(Arg));
send_ok(State, Arg) when is_atom(Arg) -> send_ok(State, atom_to_list(Arg));
send_ok(State, Arg) when is_list(Arg)-> send_ok(State, list_to_binary(Arg)).

start_timer(State) ->
	State1 = cancel_timer(State),
	{ok, Timer} = timer:send_after(60000, trap_timeout),
	State1#state{trap_timer=Timer}.

cancel_timer(#state{trap_timer=undefined} = State) -> State;
cancel_timer(#state{trap_timer=TT} = State) -> 
	timer:cancel(TT),
	State#state{trap_timer=undefined}.
	

