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
%%% @doc MyDLP NLP module for Turkish Language
%%% @end
%%%-------------------------------------------------------------------
-module(mydlp_nlp_tr).
-author("kerem@medra.com.tr").
-behaviour(gen_server).

-include("mydlp.hrl").

%% API
-export([start_link/0,
	normalize/1,
	kok_ozeti_bul/1,
	stop/0]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-record(state, {wordtree}).

-record(word, {
		word, 
		fi=false, 
		yum=false,
		dus=false
	}).

%%%%%%%%%%%%% API

normalize(Word) -> kok_ozeti_bul(Word).

kok_ozeti_bul(Word) -> gen_server:call(?MODULE, {kob, Word}).

%%%%%%%%%%%%%% gen_server handles

handle_call({kob, _Word}, From, State) ->
	Worker = self(),
	spawn_link(fun() ->
			Reply = 1,
			Worker ! {async_reply, Reply, From}
		end),
	{noreply, State, 15000};

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
	gen_server:cast(?MODULE, stop).

init([]) ->
	Kokler = case application:get_env(mydlp, nlp_tr_kokler) of
		{ok, Path} -> Path;
		undefined -> ?NLP_TR_KOKLER end,
	WT = populate_word_tree(Kokler),
	erlang:display(WT),
	{ok, #state{wordtree=WT}}.

handle_cast(stop, State) ->
	{stop, normal, State};

handle_cast(_Msg, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

populate_word_tree(KoklerPath) ->
	{ok, Bin} = file:read_file(KoklerPath),
	populate_word_tree1(Bin, {root, gb_trees:empty()}).

populate_word_tree1(Bin, WordTree) ->
	case erlang:decode_packet(line, Bin, []) of
		{ok, Line, Rest} -> 
			Word = line_to_word(unicode:characters_to_list(Line)), 
			WordTree1 = update_word_tree(WordTree, Word),
			populate_word_tree1(Rest, WordTree1);
		_Else -> WordTree end.


update_word_tree(WT, Word) ->
	WLists = word_to_wlists(Word),
	%erlang:display({Word#word.word, WLists}),
	{root, update_word_tree(WT, Word#word.word, WLists)}.

update_word_tree(WT, WHash, [WL|WLists]) -> 
	WT1 = update_word_tree1(WT, WHash, WL),
	update_word_tree(WT1, WHash, WLists);
update_word_tree(WT, _WHash, []) -> WT.

update_word_tree1({Pre, Branch}, WHash, [C]) ->
	{Pre, case gb_trees:is_defined(C, Branch) of
		true ->
			NextBranch = gb_trees:get(C, Branch),
			gb_trees:update(C, hash_branch(WHash, NextBranch), Branch);
		false ->
			gb_trees:insert(C, hash_branch(WHash), Branch)
	end};
update_word_tree1({Pre, Branch}, WHash, [C|WL]) ->
	erlang:display(ugh),
	{Pre, case gb_trees:is_defined(C, Branch) of
		true ->
			NextBranch = gb_trees:get(C, Branch),
			NewNextBranch = update_word_tree1(NextBranch, WHash, WL),
			gb_trees:update(C, NewNextBranch, Branch);
		false ->
			NewNextBranch = update_word_tree1(empty_branch(), WHash, WL),
			gb_trees:insert(C, NewNextBranch, Branch)
	end}.

hash_branch(WHash) -> hash_branch(WHash, empty_branch()).

hash_branch(WHash, {_, Branch}) -> {{w, WHash}, Branch}.

empty_branch() -> {n, gb_trees:empty()}.

word_to_wlists(Word) -> word_to_wlists(Word, []).

word_to_wlists(#word{word=W, fi=true}=Word, Acc) ->
	WLen = string:len(W),
	W1 = case string:substr(W, WLen - 2) of
		"mak" -> string:substr(W, 1, WLen - 3);
		"mek" -> string:substr(W, 1, WLen - 3);
		_ -> W end,
	word_to_wlists(Word#word{word=W1, fi=false}, Acc);
word_to_wlists(#word{word=W, yum=true, dus=true} = Word, Acc) ->
	WLen = string:len(W),
	WP = string:substr(W, 1, WLen - 1),
	L = lists:map(fun(C) -> WP ++ [C] end, to_yum(string:substr(W, WLen, 1))),
	L2 = lists:map(fun(C) -> unlu_dusur(C) end, L),
	word_to_wlists(Word#word{yum=false, dus=false}, lists:append([L, L2, Acc]));
word_to_wlists(#word{word=W, yum=true}= Word, Acc) ->
	WLen = string:len(W),
	WP = string:substr(W, 1, WLen - 1),
	L = lists:map(fun(C) -> WP ++ [C] end, to_yum(string:substr(W, WLen, 1))),
	word_to_wlists(Word#word{yum=false}, lists:append(L, Acc));
word_to_wlists(#word{word=W, dus=true} = Word, Acc) ->
	WD = unlu_dusur(W),
	word_to_wlists(Word#word{dus=false}, [WD|Acc]);
word_to_wlists(#word{word=W}, Acc) -> lists:usort([W|Acc]).


line_to_word(Line) -> line_to_word(Line, #word{}, [], []).

line_to_word([$\s|Rest], #word{word=undefined} = Word, Tags, Acc) -> 
	line_to_word(Rest, Word#word{word=to_lower(lists:reverse(Acc))}, Tags, []);
line_to_word([$\s|Rest], Word, Tags, Acc) -> 
	line_to_word(Rest, Word, [lists:reverse(Acc)|Tags], []);
line_to_word([$\n], Word, Tags, Acc) -> 
	line_to_word([], Word, [lists:reverse(Acc)|Tags], []);
line_to_word([$\r,$\n], Word, Tags, Acc) -> 
	line_to_word([], Word, [lists:reverse(Acc)|Tags], []);
line_to_word([C|Rest], Word, Tags, Acc) -> line_to_word(Rest, Word, Tags, [C|Acc]);
line_to_word([], Word, Tags, []) -> 
	FI = lists:member("FI", Tags),
	YUM = lists:member("YUM", Tags),
	DUS = lists:member("DUS", Tags),
	Word#word{fi=FI, yum=YUM, dus=DUS}.


to_yum([C]) -> to_yum(C);

to_yum(231) -> [$c, 231];
to_yum($g) -> [$g, 287];
to_yum($k) -> [$k, 287];
to_yum($p) -> [$b, $p];
to_yum($t) -> [$d, $t];
to_yum(C) -> [C].

unlu_dusur(Str) -> unlu_dusur(lists:reverse(Str),[]).

unlu_dusur([$i|Rest], Acc) -> lists:reverse(Rest) ++ Acc;
unlu_dusur([305|Rest], Acc) -> lists:reverse(Rest) ++ Acc;
unlu_dusur([$u|Rest], Acc) -> lists:reverse(Rest) ++ Acc;
unlu_dusur([252|Rest], Acc) -> lists:reverse(Rest) ++ Acc;
unlu_dusur([C|Rest], Acc) -> unlu_dusur(Rest, [C|Acc]);
unlu_dusur([], Acc) -> Acc.

to_lower(Str) -> to_lower(Str, []).

to_lower([382|Rest], Acc) -> to_lower(Rest, [$z|Acc]); % ozel z
to_lower([381|Rest], Acc) -> to_lower(Rest, [$z|Acc]); % ozel Z
to_lower([380|Rest], Acc) -> to_lower(Rest, [$z|Acc]); % ozel z
to_lower([379|Rest], Acc) -> to_lower(Rest, [$z|Acc]); % ozel Z
to_lower([378|Rest], Acc) -> to_lower(Rest, [$z|Acc]); % ozel z
to_lower([377|Rest], Acc) -> to_lower(Rest, [$z|Acc]); % ozel Z
to_lower([376|Rest], Acc) -> to_lower(Rest, [$y|Acc]); % ozel Y
to_lower([375|Rest], Acc) -> to_lower(Rest, [$y|Acc]); % ozel y
to_lower([374|Rest], Acc) -> to_lower(Rest, [$y|Acc]); % ozel Y
to_lower([373|Rest], Acc) -> to_lower(Rest, [$w|Acc]); % ozel w
to_lower([372|Rest], Acc) -> to_lower(Rest, [$w|Acc]); % ozel W
to_lower([371|Rest], Acc) -> to_lower(Rest, [$u|Acc]); % ozel u
to_lower([370|Rest], Acc) -> to_lower(Rest, [$u|Acc]); % ozel U
to_lower([369|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel u-
to_lower([368|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel U-
to_lower([367|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel u-
to_lower([366|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel U-
to_lower([365|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel u-
to_lower([364|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel U-
to_lower([363|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel u-
to_lower([362|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel U-
to_lower([361|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel u-
to_lower([360|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel U-
to_lower([359|Rest], Acc) -> to_lower(Rest, [$t|Acc]); % ozel t
to_lower([358|Rest], Acc) -> to_lower(Rest, [$t|Acc]); % ozel T
to_lower([357|Rest], Acc) -> to_lower(Rest, [$t|Acc]); % ozel t
to_lower([356|Rest], Acc) -> to_lower(Rest, [$t|Acc]); % ozel T
to_lower([355|Rest], Acc) -> to_lower(Rest, [$t|Acc]); % ozel t
to_lower([354|Rest], Acc) -> to_lower(Rest, [$t|Acc]); % ozel T
to_lower([353|Rest], Acc) -> to_lower(Rest, [$s|Acc]); % ozel s
to_lower([352|Rest], Acc) -> to_lower(Rest, [$s|Acc]); % ozel S
to_lower([351|Rest], Acc) -> to_lower(Rest, [351|Acc]); % s-
to_lower([350|Rest], Acc) -> to_lower(Rest, [351|Acc]); % S-
to_lower([349|Rest], Acc) -> to_lower(Rest, [$s|Acc]); % ozel s
to_lower([348|Rest], Acc) -> to_lower(Rest, [$s|Acc]); % ozel S
to_lower([347|Rest], Acc) -> to_lower(Rest, [$s|Acc]); % ozel s
to_lower([346|Rest], Acc) -> to_lower(Rest, [$s|Acc]); % ozel S
to_lower([345|Rest], Acc) -> to_lower(Rest, [$r|Acc]); % ozel r
to_lower([344|Rest], Acc) -> to_lower(Rest, [$r|Acc]); % ozel R
to_lower([343|Rest], Acc) -> to_lower(Rest, [$r|Acc]); % ozel r
to_lower([342|Rest], Acc) -> to_lower(Rest, [$r|Acc]); % ozel R
to_lower([341|Rest], Acc) -> to_lower(Rest, [$r|Acc]); % ozel r
to_lower([340|Rest], Acc) -> to_lower(Rest, [$r|Acc]); % ozel R
to_lower([337|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel o-
to_lower([336|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel O-
to_lower([335|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel o-
to_lower([334|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel O-
to_lower([333|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel o-
to_lower([332|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel O-
to_lower([331|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel n
to_lower([330|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel N
to_lower([329|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel n
to_lower([328|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel n
to_lower([327|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel N
to_lower([326|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel n
to_lower([325|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel N
to_lower([324|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel n
to_lower([323|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel N
to_lower([322|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel l
to_lower([321|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel L
to_lower([320|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel l
to_lower([319|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel L
to_lower([318|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel l
to_lower([317|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel L
to_lower([316|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel l
to_lower([315|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel L
to_lower([314|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel l
to_lower([313|Rest], Acc) -> to_lower(Rest, [$l|Acc]); % ozel L
to_lower([312|Rest], Acc) -> to_lower(Rest, [$k|Acc]); % ozel k
to_lower([311|Rest], Acc) -> to_lower(Rest, [$k|Acc]); % ozel k
to_lower([310|Rest], Acc) -> to_lower(Rest, [$k|Acc]); % ozel K
to_lower([309|Rest], Acc) -> to_lower(Rest, [$j|Acc]); % ozel j
to_lower([308|Rest], Acc) -> to_lower(Rest, [$j|Acc]); % ozel J
to_lower([307|Rest], Acc) -> to_lower(Rest, [$j|Acc]); % ozel j
to_lower([306|Rest], Acc) -> to_lower(Rest, [$j|Acc]); % ozel J
to_lower([305|Rest], Acc) -> to_lower(Rest, [305|Acc]); % i-
to_lower([304|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % I-
to_lower([303|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel i
to_lower([302|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel I-
to_lower([301|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel i
to_lower([300|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel I-
to_lower([299|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel i
to_lower([298|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel I-
to_lower([297|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel i
to_lower([296|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel I-
to_lower([295|Rest], Acc) -> to_lower(Rest, [$h|Acc]); % ozel h
to_lower([294|Rest], Acc) -> to_lower(Rest, [$h|Acc]); % ozel H
to_lower([293|Rest], Acc) -> to_lower(Rest, [$h|Acc]); % ozel h
to_lower([292|Rest], Acc) -> to_lower(Rest, [$h|Acc]); % ozel H
to_lower([291|Rest], Acc) -> to_lower(Rest, [287|Acc]); % ozel g-
to_lower([290|Rest], Acc) -> to_lower(Rest, [287|Acc]); % ozel G-
to_lower([289|Rest], Acc) -> to_lower(Rest, [287|Acc]); % ozel g-
to_lower([288|Rest], Acc) -> to_lower(Rest, [287|Acc]); % ozel G-
to_lower([287|Rest], Acc) -> to_lower(Rest, [287|Acc]); % g-
to_lower([286|Rest], Acc) -> to_lower(Rest, [287|Acc]); % G-
to_lower([285|Rest], Acc) -> to_lower(Rest, [287|Acc]); % ozel g-
to_lower([284|Rest], Acc) -> to_lower(Rest, [287|Acc]); % ozel G-
to_lower([283|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([282|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([281|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([280|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([279|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([278|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([277|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([276|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([275|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([274|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([273|Rest], Acc) -> to_lower(Rest, [$d|Acc]); % ozel d
to_lower([272|Rest], Acc) -> to_lower(Rest, [$d|Acc]); % ozel D
to_lower([271|Rest], Acc) -> to_lower(Rest, [$d|Acc]); % ozel d
to_lower([270|Rest], Acc) -> to_lower(Rest, [$d|Acc]); % ozel D
to_lower([269|Rest], Acc) -> to_lower(Rest, [$c|Acc]); % ozel c
to_lower([268|Rest], Acc) -> to_lower(Rest, [$c|Acc]); % ozel C
to_lower([267|Rest], Acc) -> to_lower(Rest, [$c|Acc]); % ozel c
to_lower([266|Rest], Acc) -> to_lower(Rest, [$c|Acc]); % ozel C
to_lower([265|Rest], Acc) -> to_lower(Rest, [$c|Acc]); % ozel c
to_lower([264|Rest], Acc) -> to_lower(Rest, [$c|Acc]); % ozel C
to_lower([263|Rest], Acc) -> to_lower(Rest, [$c|Acc]); % ozel c
to_lower([262|Rest], Acc) -> to_lower(Rest, [$c|Acc]); % ozel C
to_lower([261|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([260|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([259|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([258|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([257|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([256|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([255|Rest], Acc) -> to_lower(Rest, [$y|Acc]); % ozel y
to_lower([253|Rest], Acc) -> to_lower(Rest, [$y|Acc]); % ozel y
to_lower([252|Rest], Acc) -> to_lower(Rest, [252|Acc]); % u-
to_lower([251|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel u
to_lower([250|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel u-
to_lower([249|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel u-
to_lower([248|Rest], Acc) -> to_lower(Rest, [$0|Acc]); % ozel 0
to_lower([246|Rest], Acc) -> to_lower(Rest, [246|Acc]); % o-
to_lower([245|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel o
to_lower([244|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel o
to_lower([243|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel o
to_lower([242|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel o
to_lower([241|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel n
to_lower([240|Rest], Acc) -> to_lower(Rest, [$d|Acc]); % ozel d
to_lower([239|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel i
to_lower([238|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel i
to_lower([237|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel i
to_lower([236|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel i
to_lower([235|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([234|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([233|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([232|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel e
to_lower([231|Rest], Acc) -> to_lower(Rest, [231|Acc]); % c-
to_lower([230|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel a
to_lower([229|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel a
to_lower([228|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel a
to_lower([227|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel a
to_lower([226|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel a
to_lower([225|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel a
to_lower([224|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel a
to_lower([223|Rest], Acc) -> to_lower(Rest, [$b|Acc]); % ozel B
to_lower([221|Rest], Acc) -> to_lower(Rest, [$y|Acc]); % ozel Y
to_lower([220|Rest], Acc) -> to_lower(Rest, [252|Acc]); % U-
to_lower([219|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel U-
to_lower([218|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel U-
to_lower([217|Rest], Acc) -> to_lower(Rest, [252|Acc]); % ozel U-
to_lower([216|Rest], Acc) -> to_lower(Rest, [$0|Acc]); % ozel 0
to_lower([215|Rest], Acc) -> to_lower(Rest, [$x|Acc]); % ozel x
to_lower([214|Rest], Acc) -> to_lower(Rest, [246|Acc]); % O-
to_lower([213|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel O
to_lower([212|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel O
to_lower([211|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel O
to_lower([210|Rest], Acc) -> to_lower(Rest, [246|Acc]); % ozel O
to_lower([209|Rest], Acc) -> to_lower(Rest, [$n|Acc]); % ozel N
to_lower([208|Rest], Acc) -> to_lower(Rest, [$d|Acc]); % ozel D
to_lower([207|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel I-
to_lower([206|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel I-
to_lower([205|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel I-
to_lower([204|Rest], Acc) -> to_lower(Rest, [$i|Acc]); % ozel I-
to_lower([203|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([202|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([201|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([200|Rest], Acc) -> to_lower(Rest, [$e|Acc]); % ozel E
to_lower([199|Rest], Acc) -> to_lower(Rest, [231|Acc]); % C-
to_lower([198|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([197|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([196|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([195|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([194|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([193|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([192|Rest], Acc) -> to_lower(Rest, [$a|Acc]); % ozel A
to_lower([73|Rest], Acc) -> to_lower(Rest, [305|Acc]); % i-
to_lower([C|Rest], Acc) ->
	C1 = case ( C >= 65) and ( 90 >= C ) of
		true -> C + 32;
		false -> C end,
	to_lower(Rest, [C1|Acc]);
to_lower([], Acc) -> lists:reverse(Acc).
