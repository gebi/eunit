%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% The Initial Developer of the Original Code is Richard Carlsson.''
%%
%% File: eunit_code.erl
%%
%% $Id:$ 
%%
%% @author Richard Carlsson <richardc@it.uu.se>
%% @copyright 2006 Richard Carlsson
%% @private
%% @see eunit
%% @doc EUnit code watching service

-module(eunit_code).

-export([start/0, start/1, stop/0, stop/1, subscribe/1, subscribe/2,
	 unsubscribe/1, unsubscribe/2, install_codespy/1, wiretap/3]).


-define(WATCHER, code_watcher).

subscribe(Pid) ->
    subscribe(?WATCHER, Pid).

subscribe(Server, Pid) when is_pid(Pid) ->
    ensure_started(Server),
    Server ! {subscribe, Pid},
    ok.

unsubscribe(Pid) ->
    unsubscribe(?WATCHER, Pid).

unsubscribe(Server, Pid) when is_pid(Pid) ->
    ensure_started(Server),
    Server ! {unsubscribe, Pid},
    ok.

stop() ->
    stop(?WATCHER).

stop(Server) ->
    Server ! stop,
    ok.
	    
ensure_started(Name) when is_atom(Name) ->
    start(Name);
ensure_started(Pid) when is_pid(Pid) ->
    Pid.

start() ->
    start(?WATCHER).

start(Name) ->
    case whereis(Name) of
	undefined ->
	    Parent = self(),
	    Pid = spawn(fun () -> watcher_init(Name, Parent) end),
	    receive
		{Pid, Result} -> Result
	    end;
	Pid -> Pid
    end.

watcher_init(Name, Parent) ->
    Self = self(),
    case catch register(Name, Self) of
	true ->
	    case install_codespy(Self) of
		{ok, _Spy} ->
		    Parent ! {Self, ok},
		    watcher(Name, sets:new());
		{error, R} ->
		    Parent ! {Self, {error, R}}
	    end;
	_ ->
	    Parent ! {Self, {error, failed}}    
    end.

watcher(Name, Listeners) ->
    receive
	{code_server, {module, M}} ->
	    cast({Name, {loaded, M}}, Listeners),
	    watcher(Name, Listeners);
	{subscribe, Pid} when is_pid(Pid) ->
	    watcher(Name, sets:add_element(Pid, Listeners));
	{unsubscribe, Pid} ->
	    watcher(Name, sets:del_element(Pid, Listeners));
	stop ->
	    exit(normal);
	_ ->
	    watcher(Name, Listeners)
    end.

cast(M, Listeners) ->
    sets:fold(fun (L, M) -> L ! M end, M, Listeners).


%% code server spy using generic wiretap functionality

install_codespy(To) ->
    wiretap(code_server, To, fun code_spy/3).

code_spy({code_call,From,{load_file,_}=Req}, Server, To) ->
    handle_load(Req, From, Req, Server, To);
code_spy({code_call,From,{ensure_loaded,_}=Req}, Server, To) ->
    handle_load(Req, From, Req, Server, To);
code_spy({code_call,From,{load_abs,_,_}=Req}, Server, To) ->
    handle_load(Req, From, Req, Server, To);
code_spy({code_call,From,{load_binary,_,_,_}=Req}, Server, To) ->
    handle_load(Req, From, Req, Server, To);
code_spy({code_call,From,{load_native_partial,_,_}=Req}, Server, To) ->
    handle_load(Req, From, Req, Server, To);
code_spy({code_call,From,{load_native_sticky,_,_,_}=Req}, Server, To) ->
    handle_load(Req, From, Req, Server, To);
code_spy(M, Server, _To) ->
    Server ! M.

handle_load(Req, From, Req, Server, To) ->
    ReplyTo = spawn(fun () -> reply_handler(Server, From, To) end),
    Server ! {code_call, ReplyTo, Req}.

%% one-shot processes - receive, pass on and die
reply_handler(Server, Client, To) ->
    link(Server),
    receive
	{code_server, _Reply} = M ->
	    To ! Client ! M
    end.


%% basic wiretapping of registered processes

wiretap(Name, To, F) when is_atom(Name), is_pid(To), is_function(F) ->
    Parent = self(),
    Pid = spawn(fun () -> wiretap_init(Name, To, F, Parent) end),
    receive
	{Pid, Result} -> Result
    end.

wiretap_init(Name, To, F, Parent) ->
    case whereis(Name) of
	undefined ->
	    Parent ! {self(), {error, undefined}},
	    exit(error);
	Pid ->
	    catch unregister(Name),
	    catch register(Name, self()),
	    Self = self(),
	    case whereis(Name) of
		Self ->
		    process_flag(trap_exit, true),
		    link(Pid),
		    link(To),
		    Parent ! {self(), {ok, self()}},
		    wiretap_loop(Name, To, Pid, F);
		_ ->
		    Parent ! {self(), {error, register_failed}},
		    exit(error)
	    end
    end.

wiretap_loop(Name, To, Pid, F) ->
    receive
	{'EXIT', Pid, _} ->
	    wiretap_dropped(Name, To, F);
	{'EXIT', To, _} ->
	    wiretap_exit(Name, Pid);
	Msg ->
	    F(Msg, Pid, To),
	    wiretap_loop(Name, To, Pid, F)
    end.

wiretap_exit(Name, Pid) ->
    %% the receiver died - restore things and go away invisibly
    unlink(Pid),
    Self = self(),
    case whereis(Name) of
	Self ->
	    catch unregister(Name),
	    catch register(Name, Pid);
	_ -> ok
    end,
    exit(normal).

%% if the real server goes away, make sure to unregister, and keep watch
%% in order to restart the wiretap when the server comes up again

wiretap_dropped(Name, To, F) ->
    Self = self(),
    case whereis(Name) of
	Self -> (catch unregister(Name));
	_ -> ok
    end,
    wiretap_watch(Name, To, F).

wiretap_watch(Name, To, F) ->
    receive
	{'EXIT', To, _} ->
	    exit(normal)
    after 1000 ->
	case whereis(Name) of
	    Pid when is_pid(Pid) ->
		%% this process will terminate after starting the
		%% new wiretap (even it that call fails)
		wiretap(Name, To, F),
		exit(normal);
	    _ -> 
		wiretap_watch(Name, To, F)
	end
    end.