%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2014, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 18 Jan 2014 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(ensq_topic).

-behaviour(gen_server).

%% API
-export([get_info/1, list/0,
         discover/3, discover/4,
         add_channel/3,
         send/2,
         start_link/2]).

%% Internal
-export([tick/1, do_retry/3]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(MAX_RETRIES, 10).

-define(RETRY_TIMEOUT, 1000).

-record(state, {
          ref2srv = [],
          topic,
          discovery_servers = [],
          discover_interval = 60000,
          servers = [],
          channels = [],
          targets = [],
          targets_rev = []
         }).

%%%===================================================================
%%% API
%%%===================================================================

list() ->
    Children = supervisor:which_children(ensq_topic_sup),
    [get_info(Pid) || {_,Pid,_,_} <- Children].

get_info(Pid) ->
    gen_server:call(Pid, get_info).

add_channel(Topic, Channel, Handler) ->
    gen_server:cast(Topic, {add_channel, Channel, Handler}).

-spec discover(Topic :: ensq:topic_name(), Hosts :: [ensq:hosts()],
               Channels :: [ensq:channel()]) -> {ok, Pid :: pid()}.

discover(Topic, Hosts, Channels) ->
    discover(Topic, Hosts, Channels, []).

discover(Topic, Hosts, Channels, Targets) when is_list(Hosts)->
    ensq_topic_sup:start_child(Topic, {discovery, Hosts, Channels, Targets});

discover(Topic, Host, Channels, Targets) ->
    discover(Topic, [Host], Channels, Targets).


send(Topic, Msg) ->
    gen_server:call(Topic, {send, Msg}).

retry(Delay, Srv, Ref) ->
    retry(self(), Delay, Srv, Ref).

retry(Pid, Delay, Srv, Ref) ->
    timer:apply_after(Delay, ensq_topic, do_retry, [Pid, Srv, Ref]).

do_retry(Pid, Srv, Ref) ->
    gen_server:cast(Pid, {retry, Srv, Ref}).

tick() ->
    tick(self()).

tick(Pid) ->
    gen_server:cast(Pid, tick).
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Topic, Spec) when is_binary(Topic) ->
    gen_server:start_link(?MODULE, [Topic, Spec], []);

start_link(Topic, Spec) ->
    gen_server:start_link({local, Topic}, ?MODULE, [Topic, Spec], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Topic, {discovery, Ds, Channels, Targets}]) when is_binary(Topic) ->
    tick(),
    {ok, #state{topic = binary_to_list(Topic), discovery_servers = Ds,
                channels = Channels, targets = Targets}};

init([Topic, {discovery, Ds, Channels, Targets}]) ->
    tick(),
    {ok, #state{topic = atom_to_list(Topic), discovery_servers = Ds,
                channels = Channels, targets = Targets}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(get_info, _From, State =
                #state{
                   channels = Channels,
                   topic = Topic,
                   servers = Servers
                  }) ->
    Reply = {self(), Topic, Channels, Servers},
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({add_channel, Channel, Handler},
            State = #state{channels = Cs, servers = Ss}) ->
    Topic = list_to_binary(State#state.topic),
    Ss1 = orddict:map(
            fun({Host, Port}, Pids) ->
                    E = ensq_connection:open(Host, Port, Topic, Channel, Handler),
                    Ref = erlang:monitor(process, E),
                    io:format("Reply: ~p~n", [E]),
                    {ok, Pid} = E,
                    [{Pid, Channel, Handler, Ref, 0} | Pids]
            end, Ss),
    {noreply, State#state{servers = Ss1, channels = [{Channel, Handler} | Cs],
                          ref2srv = build_ref2srv(Ss1)}};

handle_cast(tick, State = #state{discovery_servers = []}) ->
    {noreply, State};

handle_cast(tick, State = #state{
                             discovery_servers = Hosts,
                             topic = Topic,
                             discover_interval = I
                            }) ->
    URLTail = "/lookup?topic=" ++ Topic,
    State1 =
        lists:foldl(fun ({H, Port}, Acc) ->
                            Host = H ++ ":" ++ integer_to_list(Port),
                            URL ="http://" ++ Host ++ URLTail,
                            case http_get(URL) of
                                {ok, JSON} ->
                                    add_discovered(JSON, Acc);
                                _ ->
                                    Acc
                                end
                    end, State, Hosts),
    %% Add +/- 10% Jitter for the next discovery
    D = round(I/10),
    T = I + random:uniform(D*2) - D,
    timer:apply_after(T, ensq_topic, tick, [self()]),
    {noreply, State1};

handle_cast(_Msg, State) ->
    {noreply, State}.


add_discovered(JSON, State) ->
    {ok, Producers} = jsxd:get([<<"data">>, <<"producers">>], JSON),
    Producers1 = [get_host(P) || P <- Producers],
    lists:foldl(fun add_host/2, State, Producers1).

add_host({Host, Port}, State = #state{servers = Srvs, channels = Cs, ref2srv = R2S}) ->
    case orddict:is_key({Host, Port}, Srvs) of
        true ->
            State;
        false ->
            Topic = list_to_binary(State#state.topic),
            io:format("New: ~s:~p", [Host, Port]),
            Pids = [{ensq_connection:open(Host, Port, Topic, Channel, Handler),
                     Channel, Handler} || {Channel, Handler} <- Cs],
            Pids1 = [{Pid, Channel, Handler, erlang:monitor(process, Pid), 0} ||
                        {{ok, Pid}, Channel, Handler} <- Pids],
            Refs = [{Ref, {Host, Port}} || {_, _, _, Ref, _} <- Pids1],
            State#state{servers = orddict:store({Host, Port}, Pids1, Srvs),
                        ref2srv = Refs ++ R2S}
    end.

build_ref2srv(D) ->
    build_ref2srv(D, []).
build_ref2srv([], Acc) ->
    Acc;
build_ref2srv([{_Srv, []} | R], Acc) ->
    build_ref2srv(R, Acc);
build_ref2srv([{Srv, [{_, _, _, Ref, _} | RR]} | R], Acc) ->
    build_ref2srv([{Srv, RR} | R], [{Ref, Srv} | Acc]).


get_host(Producer) ->
    {ok, Addr} = jsxd:get(<<"broadcast_address">>, Producer),
    {ok, Port} = jsxd:get(<<"tcp_port">>, Producer),
    {binary_to_list(Addr), Port}.

http_get(URL) ->
    case httpc:request(get, {URL,[]}, [], [{body_format, binary}]) of
        {ok,{{_,200,_}, _, Body}} ->
            {ok, jsx:decode(Body)};
        _ ->
            error
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_info({'DOWN', Ref, _, _, _}, State = #state{servers=Ss, ref2srv=R2S}) ->
    State1 = State#state{ref2srv = lists:keydelete(Ref, 1, R2S)},
    {Ref, Srv} = lists:keyfind(Ref, 1, R2S),
    SrvData = orddict:fetch(Srv, Ss),
    case down_ref(Srv, Ref, SrvData) of
        delete ->
            {noreply, State1#state{servers=orddict:erase(Srv, Ss)}};
        SrvData1 ->
            {noreply, State1#state{servers=orddict:store(Srv, SrvData1, Ss)}}
    end;

handle_info(_, State) ->
    {noreply, State}.

down_ref(_, Ref, [{_, _, _, Ref, _}]) ->
    delete;
down_ref(_, _, []) ->
    delete;
down_ref(Srv, Ref, Records) ->
    Recods1 = lists:keydelete(Ref, 4, Records),
    case lists:keyfind(Ref, 4, Records) of
        {_Pid, _Channel, _Handler, Ref, Retries}
          when Retries >= ?MAX_RETRIES ->
            Recods1;
        {_, Channel, Handler, Ref, Retries} ->
            Retries1 = Retries + 1,
            Delay = ?RETRY_TIMEOUT * Retries1,
            retry(Delay, Srv, Ref),
            [{undefined, Channel, Handler, Ref, Retries+1} | Recods1];
        _ ->
            Recods1
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
