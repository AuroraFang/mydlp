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

%%%-------------------------------------------------------------------
%%% @author H. Kerem Cevahir <kerem@medratech.com>
%%% @copyright 2010, H. Kerem Cevahir
%%% @doc Matcher repository for mydlp.
%%% @end
%%%-------------------------------------------------------------------
-module(mydlp_matchers).
-author("kerem@medra.com.tr").

-include("mydlp.hrl").

%% API
-export([
	mime_match/2,
	regex_match/2
]).

-include_lib("eunit/include/eunit.hrl").

mime_match(MimeTypes, {_Addr, Files}) -> mime_match(MimeTypes, Files);
mime_match(MimeTypes, [File|Files]) ->
	MT = case File#file.mime_type of 
		undefined -> mydlp_tc:get_mime(File#file.data);
		Else -> Else
	end,

	case lists:member(MT, MimeTypes) of
		true -> pos;
		false -> mime_match(MimeTypes, Files)
	end;
mime_match(_MimeTypes, []) -> neg.

regex_match(RGIs, {_Addr, Files}) -> regex_match(RGIs, Files);
regex_match(RGIs, [File|Files]) ->
	case mydlp_regex:match(RGIs, File#file.text) of
		true -> pos;
		false -> regex_match(RGIs, Files)
	end;
regex_match(_RGIs, []) -> neg.
