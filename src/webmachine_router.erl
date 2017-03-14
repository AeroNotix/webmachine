%% @author Kevin A. Smith <ksmith@basho.com>
%% @copyright 2007-2010 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

%% @doc Module to add and remove dynamic routes to webmachine's routing
%%      table. Dynamic routes are not persistent between executions of
%%      a webmachine application. They will need to be added to the
%%      the table each time webmachine restarts.
-module(webmachine_router).

-behaviour(gen_server).

%% API
-export([start_link/0,
         add_route/1,
         add_route/2,
         remove_route/1,
         remove_route/2,
         remove_resource/1,
         remove_resource/2,
         get_routes/0,
         get_routes/1,
         init_routes/1,
         init_routes/2
        ]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% @type hostmatchterm() = {hostmatch(), [pathmatchterm()]}.
% The dispatch configuration contains a list of these terms, and the
% first one whose host and one pathmatchterm match is used.

%% @type pathmatchterm() = {[pathterm()], matchmod(), matchopts()}.
% The dispatch configuration contains a list of these terms, and the
% first one whose list of pathterms matches the input path is used.

%% @type pathterm() = '*' | string() | atom().
% A list of pathterms is matched against a '/'-separated input path.
% The '*' pathterm matches all remaining tokens.
% A string pathterm will match a token of exactly the same string.
% Any atom pathterm other than '*' will match any token and will
% create a binding in the result if a complete match occurs.

%% @type matchmod() = atom().
% This atom, if present in a successful matchterm, will appear in
% the resulting dispterm.  In Webmachine this is used to name the
% resource module that will handle the matching request.

%% @type matchopts() = [term()].
% This term, if present in a successful matchterm, will appear in
% the resulting dispterm.  In Webmachine this is used to provide
% arguments to the resource module handling the matching request.

-define(SERVER, ?MODULE).

%% State for this gen_server
%%
%% state => true, gen_server is ets router table managed by
%% webmachine_router_ets_table
-record(state, {ready = false :: boolean()}).

%% @spec add_route(hostmatchterm() | pathmatchterm()) -> ok
%% @doc Adds a route to webmachine's route table. The route should
%%      be the format documented here:
%% http://bitbucket.org/justin/webmachine/wiki/DispatchConfiguration
add_route(Route) ->
    add_route(default, Route).

add_route(Name, Route) ->
    gen_server:call(?SERVER, {add_route, Name, Route}, infinity).

%% @spec remove_route(hostmatchterm() | pathmatchterm()) -> ok
%% @doc Removes a route from webamchine's route table. The route
%%      route must be properly formatted
%% @see add_route/2
remove_route(Route) ->
    remove_route(default, Route).

remove_route(Name, Route) ->
    gen_server:call(?SERVER, {remove_route, Name, Route}, infinity).

%% @spec remove_resource(atom()) -> ok
%% @doc Removes all routes for a specific resource module.
remove_resource(Resource) when is_atom(Resource) ->
    remove_resource(default, Resource).

remove_resource(Name, Resource) when is_atom(Resource) ->
    gen_server:call(?SERVER, {remove_resource, Name, Resource}, infinity).

%% @spec get_routes() -> [{[], res, []}]
%% @doc Retrieve a list of routes and resources set in webmachine's
%%      route table.
get_routes() ->
    get_routes(default).

get_routes(Name) ->
    get_dispatch_list(Name).

%% @spec init_routes([hostmatchterm() | pathmatchterm()]) -> ok
%% @doc Set the default routes, unless the routing table isn't empty.
init_routes(DefaultRoutes) ->
    init_routes(default, DefaultRoutes).

init_routes(Name, DefaultRoutes) ->
    gen_server:call(?SERVER, {init_routes, Name, DefaultRoutes}, infinity).

%% @spec start_link() -> {ok, pid()} | {error, any()}
%% @doc Starts the webmachine_router gen_server.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @private
init([]) ->
    init_router_table(),
    {ok, #state{ready = false}}.

handle_call({remove_resource, Name, Resource}, _From, #state{ready = true} = State) ->
    DL = filter_by_resource(Resource, get_dispatch_list(Name)),
    {reply, set_dispatch_list(Name, DL), State};

handle_call({remove_route, Name, Route}, _From, #state{ready = true} = State) ->
    DL = [D || D <- get_dispatch_list(Name),
               D /= Route],
    {reply, set_dispatch_list(Name, DL), State};

handle_call({add_route, Name, Route}, _From, #state{ready = true} = State) ->
    DL = [Route|[D || D <- get_dispatch_list(Name),
                      D /= Route]],
    {reply, set_dispatch_list(Name, DL), State};

handle_call({init_routes, Name, DefaultRoutes}, _From, #state{ready = true} = State) ->
    %% if the table lacks a dispatch_list row, set it
    ets:insert_new(?MODULE, {Name, DefaultRoutes}),
    {reply, ok, State};

handle_call(_Request, _From, #state{ready = false} = State) ->
    {stop, not_ready, State};

handle_call(_Request, _From, State) ->
  {reply, ignore, State}.

%% @private
handle_cast(_Msg, State) ->
  {noreply, State}.

%% @private
handle_info({'ETS-TRANSFER', _Table, _FromPid, _GiftData}, State) ->
    {noreply, State#state{ready = true}};

handle_info(_Info, State) ->
  {noreply, State}.

%% @private
terminate(_Reason, _State) ->
  ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% Internal functions

init_router_table() ->
    case application:get_env(webmachine, become_router_table_owner, true) of
        true ->
            webmachine_router_ets_table:become_owner();
        false ->
            ok
    end.

%% @doc Remove any dispatch rule that directs requests to `Resource'
filter_by_resource(Resource, Dispatch) ->
    lists:foldr(filter_by_resource(Resource), [], Dispatch).

filter_by_resource(Resource) ->
    fun({_, R, _}, Acc) when R == Resource -> % basic dispatch
            Acc;
       ({_, _, R, _}, Acc) when R == Resource -> % guarded dispatch
            Acc;
       ({Host, Disp}, Acc) -> % host-based dispatch
            [{Host, filter_by_resource(Resource, Disp)}|Acc];
       (Other, Acc) -> % dispatch not mentioning this resource
            [Other|Acc]
    end.

get_dispatch_list(Name) ->
    case ets:lookup(?MODULE, Name) of
        [{Name, Dispatch}] ->
            Dispatch;
        [] ->
            []
    end.

set_dispatch_list(Name, DispatchList) ->
    true = ets:insert(?MODULE, {Name, DispatchList}),
    ok.

%%
%% Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

webmachine_router_test_() ->
    {setup,
     fun() ->
             application:set_env(webmachine, become_router_table_owner, true),
             {ok, Pid} = webmachine_sup:start_link(),
             unlink(Pid),
             {Pid}
     end,
     fun({SupPid}) ->
             [begin supervisor:terminate_child(webmachine_sup, ChildPid),
                    wait_for_termination(ChildPid)
              end || ChildPid <- get_children(webmachine_sup)],
             exit(SupPid, normal),
             wait_for_termination(webmachine_sup)
             %% the test process owns the table, so we clear it between tests
             %% ets:delete(?MODULE)
     end,
     [{"add_remove_route", fun add_remove_route/0},
      {"add_remove_resource", fun add_remove_resource/0},
      {"no_dupe_path", fun no_dupe_path/0},
      {"table_manager", fun table_manager/0},
      {"not_initialized", fun not_initialized/0}
     ]}.

%% Wait until the given registered name cannot be found, to ensure that
%% another test can safely start it again via start_link
wait_for_termination(RegName) ->
    IdOrUndefined = whereis(RegName),
    case IdOrUndefined of
        undefined ->
            ok;
        _ ->
            timer:sleep(100),
            wait_for_termination(RegName)
    end.

add_remove_route() ->
    PathSpec = {["foo"], foo, []},
    webmachine_router:add_route(PathSpec),
    ?assertEqual([PathSpec], get_routes()),
    webmachine_router:remove_route(PathSpec),
    ?assertEqual([], get_routes()),
    ok.

add_remove_resource() ->
    PathSpec1 = {["foo"], foo, []},
    PathSpec2 = {["bar"], foo, []},
    PathSpec3 = {["baz"], bar, []},
    PathSpec4 = {["foo"], fun(_) -> true end, foo, []},
    PathSpec5 = {["foo"], {webmachine_router, test_guard}, foo, []},
    webmachine_router:add_route(PathSpec1),
    webmachine_router:add_route(PathSpec2),
    webmachine_router:add_route(PathSpec3),
    webmachine_router:remove_resource(foo),
    ?assertEqual([PathSpec3], get_routes()),
    webmachine_router:add_route(PathSpec4),
    webmachine_router:remove_resource(foo),
    ?assertEqual([PathSpec3], get_routes()),
    webmachine_router:add_route(PathSpec5),
    webmachine_router:remove_resource(foo),
    ?assertEqual([PathSpec3], get_routes()),
    webmachine_router:remove_route(PathSpec3),
    [begin
         PathSpec = {"localhost", [HostPath]},
         webmachine_router:add_route(PathSpec),
         webmachine_router:remove_resource(foo),
         ?assertEqual([{"localhost", []}], get_routes()),
         webmachine_router:remove_route({"localhost", []})
     end || HostPath <- [PathSpec1, PathSpec4, PathSpec5]],
    ok.

no_dupe_path() ->
    PathSpec = {["foo"], foo, []},
    webmachine_router:add_route(PathSpec),
    webmachine_router:add_route(PathSpec),
    ?assertEqual([PathSpec], get_routes()),
    ok.

supervisor_restart_keeps_routes_test() ->
    application:set_env(webmachine, become_router_table_owner, true),
    {ok, SupPid} = webmachine_sup:start_link(),
    Pid = get_pid(webmachine_sup, webmachine_router),
    unlink(Pid),
    PathSpec = {["foo"], foo, []},
    webmachine_router:add_route(PathSpec),
    ?assertEqual([PathSpec], get_routes()),
    OldRouter = whereis(webmachine_router),
    ?assertEqual(Pid, OldRouter),
    exit(whereis(webmachine_router), normal),
    timer:sleep(100),
    %% Note: This test is currently broken and wasn't actually testing what it
    %% was supposed to
    NewRouter = undefined,
    ?assert(OldRouter /= NewRouter),
    ?assertEqual([PathSpec], get_routes()),
    exit(Pid, normal),
    exit(SupPid, normal),
    %% ets:delete(?MODULE),
    ok.

table_manager() ->
    RouterPid0 = get_pid(webmachine_sup, webmachine_router),
    ?assertEqual(RouterPid0, webmachine_router_ets_table:current_owner()),
    _ = supervisor:terminate_child(webmachine_sup, webmachine_router),
    ?assertEqual(undefined, webmachine_router_ets_table:current_owner()),
    {ok, RouterPid1} = supervisor:restart_child(webmachine_sup, webmachine_router),
    ?assertEqual(RouterPid1, webmachine_router_ets_table:current_owner()),

    {links, LinkedPids} = process_info(whereis(webmachine_router_ets_table), links),
    ?assertEqual(true, lists:member(RouterPid1, LinkedPids)).

not_initialized() ->
    supervisor:terminate_child(webmachine_sup, webmachine_router),
    application:set_env(webmachine, become_router_table_owner, false),
    supervisor:restart_child(webmachine_sup, webmachine_router),
    PathSpec = {["foo"], foo, []},
    {'EXIT', {Reason, _Stacktrace}} = (catch webmachine_router:add_route(PathSpec)),
    ?assertEqual(not_ready, Reason),
    ok.

get_pid(Sup, SupChild) ->
    [Pid] = [Pid || {Id, Pid, _, _} <- supervisor:which_children(Sup),
                    Id == SupChild],
    Pid.

get_children(Sup) ->
    [Id || {Id, _, _, _} <- supervisor:which_children(Sup)].

-endif.
