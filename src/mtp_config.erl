%%%-------------------------------------------------------------------
%%% @author Sergey <me@seriyps.ru>
%%% @copyright (C) 2018, Sergey
%%% @doc
%%% Worker that updates datacenter config and proxy secret from
%%% https://core.telegram.org/getProxySecret
%%% and
%%% https://core.telegram.org/getProxyConfig
%%% @end
%%% Created : 10 Jun 2018 by Sergey <me@seriyps.ru>
%%%-------------------------------------------------------------------
-module(mtp_config).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([get_downstream/1,
         get_downstream_safe/1,
         get_secret/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TAB, ?MODULE).
-define(SECRET_URL, "https://core.telegram.org/getProxySecret").
-define(CONFIG_URL, "https://core.telegram.org/getProxyConfig").

-define(APP, mtproto_proxy).

-record(state, {tab :: ets:tid(),
                timer :: gen_timeout:tout()}).

-ifndef(OTP_RELEASE).                           % pre-OTP21
-define(WITH_STACKTRACE(T, R, S), T:R -> S = erlang:get_stacktrace(), ).
-else.
-define(WITH_STACKTRACE(T, R, S), T:R:S ->).
-endif.

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_downstream(integer()) -> {ok, {inet:ip4_address(), inet:port_number()}}.
get_downstream_safe(DcId) ->
    case get_downstream(DcId) of
        {ok, Addr} -> Addr;
        not_found ->
            [{_, L}] = ets:lookup(?TAB, id_range),
            NewDcId = random_choice(L),
            %% Get random DC; it might return 0 and recurse aggain
            get_downstream_safe(NewDcId)
    end.

get_downstream(DcId) ->
    case ets:lookup(?TAB, {id, DcId}) of
        [] ->
            not_found;
        [{_, Ip, Port}] ->
            {ok, {Ip, Port}};
        L ->
            {_, Ip, Port} = random_choice(L),
            {ok, {Ip, Port}}
    end.

-spec get_secret() -> binary().
get_secret() ->
    [{_, Key}] = ets:lookup(?TAB, key),
    Key.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    Timer = gen_timeout:new(
              #{timeout => {env, ?APP, conf_refresh_interval, 3600},
                unit => second}),
    Tab = ets:new(?TAB, [bag,
                         protected,
                         named_table,
                         {read_concurrency, true}]),
    State = #state{tab = Tab,
                   timer = Timer},
    update(State, force),
    {ok, State}.

%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.
handle_cast(_Msg, State) ->
    {noreply, State}.
handle_info(timeout, #state{timer = Timer} =State) ->
    case gen_timeout:is_expired(Timer) of
        true ->
            update(State, soft),
            lager:info("Config updated"),
            Timer1 = gen_timeout:bump(
                       gen_timeout:reset(Timer)),
            {noreply, State#state{timer = Timer1}};
        false ->
            {noreply, State#state{timer = gen_timeout:reset(Timer)}}
    end;
handle_info(_Info, State) ->
    {noreply, State}.
terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

update(#state{tab = Tab}, force) ->
    update_key(Tab),
    update_config(Tab),
    update_ip();
update(State, _) ->
    try update(State, force)
    catch ?WITH_STACKTRACE(Class, Reason, Stack)
            lager:error(
              "Err updating proxy settings: ~s",
              [lager:pr_stacktrace(Stack, {Class, Reason})])
    end.

update_key(Tab) ->
    {ok, Body} = http_get(?SECRET_URL),
    true = ets:insert(Tab, {key, list_to_binary(Body)}).

update_config(Tab) ->
    {ok, Body} = http_get(?CONFIG_URL),
    Downstreams = parse_config(Body),
    Range = get_range(Downstreams),
    update_downstreams(Downstreams, Tab),
    update_range(Range, Tab).

parse_config(Body) ->
    Lines = string:lexemes(Body, "\n"),
    ProxyLines = lists:filter(
                   fun("proxy_for " ++ _) -> true;
                      (_) -> false
                   end, Lines),
    [parse_downstream(Line) || Line <- ProxyLines].

parse_downstream(Line) ->
    ["proxy_for",
     DcId,
     IpPort] = string:lexemes(Line, " "),
    [Ip, PortWithTrailer] = string:split(IpPort, ":", trailing),
    Port = list_to_integer(string:trim(PortWithTrailer, trailing, ";")),
    {ok, IpAddr} = inet:parse_ipv4strict_address(Ip),
    {list_to_integer(DcId),
     IpAddr,
     Port}.

get_range(Downstreams) ->
    [Id || {Id, _, _} <- Downstreams].

update_downstreams(Downstreams, Tab) ->
    [true = ets:insert(Tab, {{id, Id}, Ip, Port})
     || {Id, Ip, Port} <- Downstreams].

update_range(Range, Tab) ->
    true = ets:insert(Tab, {id_range, Range}).

update_ip() ->
    case application:get_env(?APP, ip_lookup_services) of
        undefined -> false;
        {ok, URLs} ->
            update_ip(URLs)
    end.

update_ip([Url | Fallbacks]) ->
    try
        {ok, Body} = http_get(Url),
        IpStr= string:trim(Body),
        {ok, _} = inet:parse_ipv4strict_address(IpStr), %assert
        application:set_env(?APP, external_ip, IpStr)
    catch ?WITH_STACKTRACE(Class, Reason, Stack)
            lager:error("Failed to update IP with ~s service: ~s",
                        [Url, lager:pr_stacktrace(Stack, {Class, Reason})]),
            update_ip(Fallbacks)
    end;
update_ip([]) ->
    error(ip_lookup_failed).

http_get(Url) ->
    {ok, Vsn} = application:get_key(mtproto_proxy, vsn),
    UserAgent = "MTProtoProxy/" ++ Vsn ++ " (+https://github.com/seriyps/mtproto_proxy)",
    Headers = [{"User-Agent", UserAgent}],
    {ok, {{_, 200, _}, _, Body}} =
        httpc:request(get, {Url, Headers}, [{timeout, 3000}], []),
    {ok, Body}.

random_choice(L) ->
    Idx = rand:uniform(length(L)),
    lists:nth(Idx, L).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_test() ->
    Config = ("# force_probability 1 10
proxy_for 1 149.154.175.50:8888;
proxy_for -1 149.154.175.50:8888;
proxy_for 2 149.154.162.39:80;
proxy_for 2 149.154.162.33:80;"),
    Expect = [{1, {149, 154, 175, 50}, 8888},
              {-1, {149, 154, 175, 50}, 8888},
              {2, {149, 154, 162, 39}, 80},
              {2, {149, 154, 162, 33},80}],
    ?assertEqual(Expect, parse_config(Config)).

-endif.
