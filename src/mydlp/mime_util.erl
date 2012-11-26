%%%---------------------------------------------------------------------------------------
%%% @author    Stuart Jackson <sjackson@simpleenigma.com> [http://erlsoft.org]
%%% @copyright 2006 - 2007 Simple Enigma, Inc. All Rights Reserved.
%%% @doc       Multipurpose Internet Mail Extention functions
%%% @reference See <a href="http://erlsoft.org/modules/erlmail" target="_top">Erlang Software Framework</a> for more information
%%% @reference See <a href="http://erlmail.googlecode.com" target="_top">ErlMail Google Code Repository</a> for more information
%%% @version   0.0.6
%%% @since     0.0.6
%%% @end
%%%
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2007 Stuart Jackson, Simple Enigma, Inc. All Righs Reserved
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%
%%%---------------------------------------------------------------------------------------

-module(mime_util).
-author('kerem@mydlp.com').
-author('sjackson@simpleenigma.com').
-include("mydlp_smtp.hrl").

-export([decode/1, decode_multipart/2, decode_content/2]).

-export([split/1,headers/1,split_multipart/2,get_header/2,get_header/3,dec_addr/1]).

%%-------------------------------------------------------------------------
%% @spec (Mime::mime()) -> mime() | {error,Reason::atom()}
%% @doc Recursively decodes a string into a #mime{} record.
%% @end
%%-------------------------------------------------------------------------
decode(Message) when is_list(Message) -> decode(list_to_binary(Message));
decode(Message) when is_binary(Message) -> 
	MIME = split(Message),
	Headers = headers(MIME#mime.header_text),
	case lists:keysearch('content-type',1,Headers) of
		{value,{'content-type',Value}} ->
			case lists:prefix("multipart",http_util:to_lower(Value)) of
				true -> 
					Boundary = case re:run(Value, ?MP_BOUNDARY_KEY, [{capture,first}]) of
						nomatch -> get_wo_quote_after(Value);
						{match,[{S,9}]} -> get_wo_quote_after(Value, S+9) end,
					MIME1 = decode_multipart(MIME, Boundary),
					MIME1#mime{header = Headers};
				false -> MIME#mime{header = Headers, content = MIME#mime.body_text}
			end;
		_ -> MIME#mime{header = Headers, content = MIME#mime.body_text}
		%_ -> MIME#mime{header = Headers, body = MIME#mime.body_text, message = Message}
	end.

rm_trailing_dashes([]) -> [];
rm_trailing_dashes(<<>>) -> <<>>;
rm_trailing_dashes(Bin) ->
	BS = size(Bin) - 1,
	case Bin of
		<<B:BS/binary, "-">> -> rm_trailing_dashes(B);
		Else -> Else end.

decode_multipart(MIME, Boundary) ->
	Content0 = case re:run(MIME#mime.body_text, 
			mydlp_api:escape_regex(Boundary), 
			[{capture,first}] ) of
		nomatch -> [];
		{match,[{0,_}]} -> [];
		{match,[{1,_}]} -> [];
		{match,[{2,_}]} -> [];
		{match,[{I,_}]} -> 
			CSize = I - 2,
			<<C:CSize/binary, _/binary>> = MIME#mime.body_text, C end,
	Content1 = rm_trailing_dashes(Content0),
	Content = mydlp_api:rm_trailing_crlf(Content1),
	Parts = split_multipart(Boundary,MIME#mime.body_text),
	MIMEParts = lists:map(fun(P) ->
			decode(P)
		end, Parts),
	MIME#mime{content = Content, body = MIMEParts}.

dec_addrs(AddrList) ->
	List = string:tokens(AddrList,[44]),
	lists:map(fun(Addr) -> 
		dec_addr(Addr)
		end,List).

dec_addr(Address) ->
	case mydlp_api:rsplit_at(Address) of
		{Email,[]} -> dec_addr2(Email,#addr{});
		{Desc,Email} -> 
			Desc1 = mydlp_api:unquote(Desc),
			Desc2 = case Desc1 of
				"=?" ++ _Rest -> mydlp_api:multipart_decode_fn_rfc2047(Desc1);
				_Else -> Desc1 end,
			dec_addr2(Email,#addr{description = Desc2})
	end.

dec_addr2(Address,Addr) ->
	A = string:strip(string:strip(Address,left,60),right,62),
	{UserName,DomainName} = mydlp_api:split_email(A),
	Addr#addr{username = UserName,domainname = DomainName}.
	



%%-------------------------------------------------------------------------
%% @spec (HeaderText::string()) -> HeaderList::list()
%% @doc Parses HeaderText into a Key/Value list
%% @end
%%-------------------------------------------------------------------------
headers(HeaderText) when is_binary(HeaderText) -> headers(binary_to_list(HeaderText));
headers(HeaderText) when is_list(HeaderText) ->
	%{ok,H,_Lines} = regexp:gsub(HeaderText,"\r\n[\t ]"," "),
	%H = re:replace(HeaderText,"\r\n[\t ]+"," ", [global, {return, list}]),
	H = re:replace(HeaderText,"\r?\n[\t ]+"," ", [global, {return, list}]),
	Tokens = string:tokens(H,[13,10]),
	headers(Tokens,[]).
%%-------------------------------------------------------------------------
%% @spec (list(),Acc::list()) -> list()
%% @hidden
%% @end
%%-------------------------------------------------------------------------
headers([H|T],Acc) ->
	Pos = string:chr(H,58),
	{HeaderString,Val} = lists:split(Pos,H),
	Value = case Header = list_to_atom(http_util:to_lower(string:strip(HeaderString,right,58))) of
		from -> dec_addr(Val);
		to   -> dec_addrs(Val);
		cc   -> dec_addrs(Val);
		bcc  -> dec_addrs(Val);
		_ -> Val
	end,
	headers(T,[head_clean(Header,Value)|Acc]);
headers([],Acc) -> lists:reverse(Acc).

head_clean(Key, #addr{} = Value) -> {Key,Value};
head_clean(Key,Value) ->
	{Key,strip(Value)}.


strip(Value) -> strip(Value,[32,9,13,10]).
strip(Value,[]) -> Value;
strip(Value,[H|T]) ->
	strip(string:strip(Value,both,H),T).

%%-------------------------------------------------------------------------
%% @spec (Part::string()) -> mime() | {error,Reason::atom()}
%% @doc Splits the part at the lcoation of two CRLF (\r\n) in a row and 
%%      returns a #mime{} record. Performs some cleanup as well. Also checks 
%%      for two LF (\n) and splits on that as some bad messages for formed 
%%      this way.
%% @end
%%-------------------------------------------------------------------------
split(Part) when is_list(Part) -> split(list_to_binary(Part));
split(Part) when is_binary(Part) ->
	case re:run(Part, ?D_CRLF_BIN, [{capture,first}]) of
		nomatch ->
			case re:run(Part, <<"\n\n">>, [{capture,first}]) of
				%nomatch -> {error,no_break_found};
				nomatch -> #mime{header_text= <<>>, body_text = Part};
				{match,[{0,2}]} -> 
					<<_Junk:2/binary, Rest/binary>> = Part, split(Rest);
				{match,[{Pos,2}]} -> 
					HeaderSize = Pos + 2,
					<<Header:HeaderSize/binary, Body/binary>> = Part,
					#mime{header_text=Header, body_text = Body} end;
		{match,[{0,4}]} -> 
			<<_Junk:4/binary, Rest/binary>> = Part, split(Rest);
		{match,[{Pos,4}]} -> 
			HeaderSize = Pos + 4,
			<<Header:HeaderSize/binary, Body/binary>> = Part,
			#mime{header_text=Header, body_text = Body} end.

%%-------------------------------------------------------------------------
%% @spec (Boundary::string(),Body::start()) -> Parts::list()
%% @doc Take the Body of a mutlipart MIME messages and split it into it's 
%%      parts on the boundary marks
%% @end
%%-------------------------------------------------------------------------
split_multipart(Boundary,Body) -> split_multipart(Boundary,Body,[]).
%%-------------------------------------------------------------------------
%% @spec (Boundary::string(),Body::start(),Acc::list()) -> Parts::list()
%% @hidden
%% @end
%%-------------------------------------------------------------------------
split_multipart(_Boundary,<<>>,Acc) -> lists:reverse(Acc);
split_multipart(Boundary,Body,Acc) when is_binary(Body)-> 
	EBoundary = mydlp_api:escape_regex("--" ++ Boundary),
	case re:run(Body, EBoundary, [{capture,first}]) of
		nomatch -> split_multipart(Boundary,<<>>,Acc);
		{match,[{Start,Length}]} when is_integer(Start) ->
			JSize = Start + Length,
			New = case Body of 
				<<_Pre:JSize/binary, "\r\n", N1/binary>> -> N1;
				<<_Pre:JSize/binary, "\n", N1/binary>> -> N1;
				<<_Pre:JSize/binary, N1/binary>> -> N1;
				_Else2 -> <<>> end,
			case re:run(New, EBoundary, [{capture,first}]) of
				nomatch -> split_multipart(Boundary,<<>>,Acc);
				{match, [{Start2, _Length2}]} when is_integer(Start2) ->
					PSize  = case Start2 - 2 of
						I when I > 0 -> I;
						_Else3 -> 0 end,
					<<P1:PSize/binary, Nx1/binary>> = New,
					{Part, Next} = case Nx1 of
						<<"\r\n--", _/binary>> -> {P1, Nx1};
						<<PS:1/binary, "\n--", Nx2/binary>> -> 
							{<<P1/binary, PS/binary>>, <<"\n--", Nx2/binary>>};
						_Else4 -> {P1, Nx1} end,
					case is_invalid_part(Part) of
						true -> split_multipart(Boundary,Next, Acc);
						false -> split_multipart(Boundary,Next,[Part|Acc])
					end
			end
	end.

is_invalid_part(<<$\r, Rest/binary>>) -> is_invalid_part(Rest);
is_invalid_part(<<$\n, Rest/binary>>) -> is_invalid_part(Rest);
is_invalid_part(<<>>) -> true;
is_invalid_part(_Else) -> false.

get_header(Key, #mime{} = MIME) -> get_header(Key,MIME#mime.header,[]);
get_header(Key,Header) -> get_header(Key,Header,[]).

get_header(Key, #mime{} = MIME,Default) -> get_header(Key,MIME#mime.header,Default);
get_header(Key,Header,Default) ->
	case lists:keysearch(Key,1,Header) of
		{value,{Key,Value}} -> Value;
		_ -> Default
	end.

decode_content("7bit", EncContent) -> decode_content('7bit', EncContent);
decode_content('7bit', EncContent) -> list_to_binary([EncContent]);
decode_content("8bit", EncContent) -> decode_content('8bit', EncContent);
decode_content('8bit', EncContent) -> list_to_binary([EncContent]);
decode_content("binary", EncContent) -> decode_content('binary', EncContent);
decode_content('binary', EncContent) -> list_to_binary([EncContent]);
decode_content("base64", EncContent) -> decode_content('base64', EncContent);
decode_content('base64', EncContent) -> base64:decode(EncContent);
decode_content("quoted-printable", EncContent) -> decode_content('quoted-printable', EncContent);
decode_content('quoted-printable', EncContent) -> mydlp_api:quoted_to_raw(EncContent);
decode_content(_Other, EncContent) -> decode_content('7bit', EncContent).

get_wo_quote_after(Value) ->
	Pos = string:chr(Value,61),
	get_wo_quote_after(Value, Pos).

get_wo_quote_after(Value, Pos) ->
	{_,B} = lists:split(Pos,Value),
	string:strip(B,both,34).

%%%%%%%%%%%%%%%%%%%%%%% Unit tests

-include_lib("eunit/include/eunit.hrl").

quoted_test() ->
	QuotedStr = <<"If you believe that truth=3Dbeauty, then surely=20=\nmathematics is the most beautiful branch of philosophy.">>,
	CleanStr = <<"If you believe that truth=beauty, then surely mathematics is the most beautiful branch of philosophy.">>,
	?assertEqual(CleanStr, decode_content('quoted-printable',QuotedStr) ).

multipart_test() ->
	RawMessage = <<"Subject: ugh\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"frontier\"\r\n\r\nThis is a message with multiple parts in MIME format.\r\n--frontier\r\nContent-Type: text/plain\r\n\r\nThis is the body of the message.\r\n--frontier\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\nPGh0bWw+CiAgPGhlYWQ+CiAgPC9oZWFkPgogIDxib2R5PgogICAgPHA+VGhpcyBpcyB0aGUg\r\nYm9keSBvZiB0aGUgbWVzc2FnZS48L3A+CiAgPC9ib2R5Pgo8L2h0bWw+Cg==\r\n--frontier-x1 -\r\n">>,
	ParsedMessage = {mime,[{subject,"ugh"},
       {'mime-version',"1.0"},
       {'content-type',"multipart/mixed; boundary=\"frontier\""}],
      <<"Subject: ugh\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"frontier\"\r\n\r\n">>,
      [{mime,[{'content-type',"text/plain"}],
             <<"Content-Type: text/plain\r\n\r\n">>,[],
             <<"This is the body of the message.">>,
             <<"This is the body of the message.">>,[]},
       {mime,[{'content-type',"application/octet-stream"},
              {'content-transfer-encoding',"base64"}],
             <<"Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n">>,
             [],
             <<"PGh0bWw+CiAgPGhlYWQ+CiAgPC9oZWFkPgogIDxib2R5PgogICAgPHA+VGhpcyBpcyB0aGUg\r\nYm9keSBvZiB0aGUgbWVzc2FnZS48L3A+CiAgPC9ib2R5Pgo8L2h0bWw+Cg==">>,
             <<"PGh0bWw+CiAgPGhlYWQ+CiAgPC9oZWFkPgogIDxib2R5PgogICAgPHA+VGhpcyBpcyB0aGUg\r\nYm9keSBvZiB0aGUgbWVzc2FnZS48L3A+CiAgPC9ib2R5Pgo8L2h0bWw+Cg==">>,
             []}],
      <<"This is a message with multiple parts in MIME format.\r\n--frontier\r\nContent-Type: text/plain\r\n\r\nThis is the body of the message.\r\n--frontier\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\nPGh0bWw+CiAgPGhlYWQ+CiAgPC9oZWFkPgogIDxib2R5PgogICAgPHA+VGhpcyBpcyB0aGUg\r\nYm9keSBvZiB0aGUgbWVzc2FnZS48L3A+CiAgPC9ib2R5Pgo8L2h0bWw+Cg==\r\n--frontier-x1 -\r\n">>,
      <<"This is a message with multiple parts in MIME format.\r\n">>,
      []},
	RawMessage2 = <<"Subject: ugh\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"--\"\r\n\r\nThis is a message with multiple parts in MIME format.\r\n----\r\nContent-Type: text/plain\r\n\r\nThis is the body of the message.\r\n----\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\nPGh0bWw+CiAgPGhlYWQ+CiAgPC9oZWFkPgogIDxib2R5PgogICAgPHA+VGhpcyBpcyB0aGUg\r\nYm9keSBvZiB0aGUgbWVzc2FnZS48L3A+CiAgPC9ib2R5Pgo8L2h0bWw+Cg==\r\n-----x1 -\r\n">>,
	ParsedMessage2 = {mime,[{subject,"ugh"},
       {'mime-version',"1.0"},
       {'content-type',"multipart/mixed; boundary=\"--\""}],
      <<"Subject: ugh\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"--\"\r\n\r\n">>,
      [{mime,[{'content-type',"text/plain"}],
             <<"Content-Type: text/plain\r\n\r\n">>,[],
             <<"This is the body of the message.">>,
             <<"This is the body of the message.">>,[]},
       {mime,[{'content-type',"application/octet-stream"},
              {'content-transfer-encoding',"base64"}],
             <<"Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n">>,
             [],
             <<"PGh0bWw+CiAgPGhlYWQ+CiAgPC9oZWFkPgogIDxib2R5PgogICAgPHA+VGhpcyBpcyB0aGUg\r\nYm9keSBvZiB0aGUgbWVzc2FnZS48L3A+CiAgPC9ib2R5Pgo8L2h0bWw+Cg==">>,
             <<"PGh0bWw+CiAgPGhlYWQ+CiAgPC9oZWFkPgogIDxib2R5PgogICAgPHA+VGhpcyBpcyB0aGUg\r\nYm9keSBvZiB0aGUgbWVzc2FnZS48L3A+CiAgPC9ib2R5Pgo8L2h0bWw+Cg==">>,
             []}],
      <<"This is a message with multiple parts in MIME format.\r\n----\r\nContent-Type: text/plain\r\n\r\nThis is the body of the message.\r\n----\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\nPGh0bWw+CiAgPGhlYWQ+CiAgPC9oZWFkPgogIDxib2R5PgogICAgPHA+VGhpcyBpcyB0aGUg\r\nYm9keSBvZiB0aGUgbWVzc2FnZS48L3A+CiAgPC9ib2R5Pgo8L2h0bWw+Cg==\r\n-----x1 -\r\n">>,
      <<"This is a message with multiple parts in MIME format.\r\n">>,
      []},
	[
	?_assertEqual(ParsedMessage, decode(RawMessage)),
	?_assertEqual(ParsedMessage2, decode(RawMessage2))
	].

