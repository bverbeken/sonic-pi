-module(pi_server).
%% --
%% This file is part of Sonic Pi: http://sonic-pi.net
%% Full project source: https://github.com/samaaron/sonic-pi
%% License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
%%
%% Copyright 2016,2017 by Joe Armstrong (http://joearms.github.io/)
%% All rights reserved.
%%
%% Permission is granted for use, copying, modification, and
%% distribution of modified versions of this work as long as this
%% notice is included.
%% ++

-export([start/1]).
-export([loop_cues/6, loop_api/4, tracker/2]).

%% Bundle Commands
%% ===============

%%   ["/send_after", Host, Port | Cmd]
%%   ["/send_after_tagged", Tag, Host, Port | Cmd]
%%
%%   Both commands send the OSC message <Cmd> to <Host,Port>
%%   at the time in the bundle header
%%
%% Immediate Commands
%%  ["/flush", <Tag>]

%% Tagged send_after's
%%   A Tag can be associated with a send-after command
%%   If no tag is explicitly named the tag called "default" is assumed
%%   ["/flush", Tag] cancels all send-after commands which have not yet
%%   been issued.
%%
%% Examples:
%%   ["/flush", "default"]
%%      cancels all send-after requests that were scheduled with
%%      a ["/send_after", Host, Port, ...] bundle
%%   ["/flush", "drums"]
%%      cancels all send-after request that were scheduled with
%%      a ["/send_after_tagged,"drums", Host, Port, ...] bundle

%% Just run pi_server:start() in a separate shell

%% Implementation notes:
%%  A hashmap (called TagMap) is added to the main loop of the server
%%   This is a map of the form #{Name1 => Pid1, Name2 => Pid2, ...}
%%   where the process PidN tracks the active timers for the tag NameN.
%%   New processes in the tagmap are created on demand.
%%   To flush a tag, we tell the corresponding tracker process to
%%   cancel its current timers.

%% Bundles whose delay time is not greater than NODELAY_LIMIT
%% are forwarded directly without starting a timer.
-define(NODELAY_LIMIT, 1).

%% set to 0 for no debugging messages
-define(DEBUG_LEVEL, 0).

%% set to 0 for no log messages
-define(LOG_LEVEL, 1).

%% time between idling messages
-define(IDLE_TIME, 60000).


debug(Msg, Vals) ->
    debug(1, Msg, Vals).

debug(Level, Msg, Vals) ->
    debug(Level, osc:now(), Msg, Vals).

debug(Level, Now, Msg, Vals) when Level =< ?DEBUG_LEVEL ->
    try io:format("~f: " ++ Msg, [Now|Vals])
    catch
        _Class:_Term ->
            io:format(standard_io,
                      "** debug format error: string=~p, args=~p~n",
                      [Msg, Vals])
    end;
debug(_Level, _Msg, _Vals, _Now) ->
    ok.


log(Msg) ->
    log(Msg, []).

log(Msg, Vals) ->
    log(1, Msg, Vals).

log(Level, Msg, Vals) when Level =< ?LOG_LEVEL ->
    try io:format(Msg, Vals)
    catch
        _Class:_Term ->
            io:format("** log format error: string=~p, args=~p~n",
                      [Msg, Vals])
    end;
log(_Level, _Msg, _Vals) ->
    ok.


cue_server_host() ->
    {127, 0, 0, 1}.

start([ARGVAPIPort, ARGVInPort, ARGVCuePort|_T]) ->
    A = atom_to_list(ARGVAPIPort),
    {Port, _Rest} = string:to_integer(A),

    B = atom_to_list(ARGVInPort),
    {InPort, _Rest} = string:to_integer(B),

    C = atom_to_list(ARGVCuePort),
    {CuePort, _Rest} = string:to_integer(C),

    CueHost = cue_server_host(),

    Internal = true,

    Enabled = false,

    io:format("~n"
              "+--------------------------------------+~n"
              "    This is the Sonic Pi IO Server      ~n"
              "       Powered by Erlang ~p             ~n"
              "                                        ~n"
              "       API listening on port ~p	       ~n"
	      "        Incoming OSC on port ~p	       ~n"
	      "  OSC cue forwarding to ~p              ~n"
              "                     on port ~p	       ~n"
              "+--------------------------------------+~n~n~n",
              [erlang:system_info(otp_release), Port, InPort, CueHost, CuePort]),

    S = self(),

    CuePid = spawn(fun() -> go_cues(S, InPort, CueHost, CuePort, Internal, Enabled) end),
    register(incoming_osc_cue_handler, CuePid),
    receive
	ack ->
	    true
    end,

    register(?MODULE, spawn(fun() -> go_api(S, Port, CuePid) end)),
    receive
	ack ->
	    true
    end.


go_cues(P, InPort, CueHost, CuePort, Internal, Enabled) ->
    case Internal of
        true ->
            {ok, InSocket} = gen_udp:open(InPort, [binary, {ip, loopback}]);
        _ ->
            {ok, InSocket} = gen_udp:open(InPort, [binary])
    end,

    P ! ack,
    debug(2, "listening for OSC cues on socket: ~p~n",
          [try erlang:port_info(InSocket) catch _:_ -> undefined end]),
    loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled).


go_api(P, Port, CuePid) ->
    {ok, APISocket} = gen_udp:open(Port, [binary, {ip, loopback}]),

    P ! ack,
    TagMap = #{},
    debug(2, "listening for API commands on socket: ~p~n",
          [try erlang:port_info(APISocket) catch _:_ -> undefined end]),
    loop_api(APISocket, 1, TagMap, CuePid).


loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled) ->
    receive

        {udp, InSocket, Ip, Port, Bin} ->
            debug(3, "cue server got UDP on ~p:~p~n", [Ip, Port]),
            case (catch osc:decode(Bin)) of
                {cmd, Cmd} ->
                    case Enabled of
                        true ->
                            debug("got incoming OSC: ~p~n", [Cmd]),
                            forward_cue(CueHost, CuePort, InSocket, Ip, Port, Cmd),
                            ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled);
                        false ->
                            debug("OSC forwarding disabled - ignored: ~p~n", [Cmd]),
                            ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled)
                    end
            end;

        {internal, true} ->
            case Internal of
                true ->
                    ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, true, Enabled);
                _ ->
                    log("Switching cue listener to loopback network~n"),
                    gen_udp:close(InSocket),
                    {ok, NewInSocket} = gen_udp:open(InPort, [binary, {ip, loopback}]),
                    ?MODULE:loop_cues(NewInSocket, InPort, CueHost, CuePort, true, Enabled)
            end;

        {internal, false} ->
            case Internal of
                true ->
                    log("Switching cue listener to open network~n"),
                    gen_udp:close(InSocket),
                    {ok, NewInSocket} = gen_udp:open(InPort, [binary]),
                    ?MODULE:loop_cues(NewInSocket, InPort, CueHost, CuePort, false, Enabled);
                _ ->
                    ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, false, Enabled)
            end;

        {enabled, true} ->
            log("Enabling cue forwarding ~n"),
            ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, true);

        {enabled, false} ->
            log("Disabling cue forwarding ~n"),
            ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, false);

        {timeout, TimerRef, {forward, Time, Data, Tracker}} ->
            send_forward(InSocket, Time, Data),
            forget_timer(TimerRef, Tracker),
            ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled);

        {forward, Time, Data} ->
            send_forward(InSocket, Time, Data),
            ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled);

        {udp_error, _Port, econnreset} ->
            %% Should not happen, but can happen anyway on Windows
            debug(2, "got UDP ECONNRESET - ignored~n", []),
            ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled);

        Any ->
	    log("Cue Server got unexpected message: ~p~n", [Any]),
	    ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled)

    after ?IDLE_TIME ->
	    debug(2, "cue server idling~n", []),
	    ?MODULE:loop_cues(InSocket, InPort, CueHost, CuePort, Internal, Enabled)
    end.

send_forward(Socket, Time, {Host, Port, Bin}) ->
    Now = osc:now(),
    send_udp(Socket, Host, Port, Bin),
    debug(1, Now, "sent message for time ~f with error ~f~n",
          [Time, Now-Time]),
    ok.

send_udp(Socket, Host, Port, Bin) ->
    catch gen_udp:send(Socket, Host, Port, Bin),
    ok.

forward_cue(CueHost, CuePort, InSocket, Ip, Port, Cmd) ->
    Bin = osc:encode(["/external-osc-cue", inet:ntoa(Ip), Port] ++ Cmd),
    send_udp(InSocket, CueHost, CuePort, Bin),
    debug("forwarded OSC cue to ~p:~p~n", [CueHost, CuePort]),
    ok.

loop_api(APISocket, N, TagMap, CuePid) ->
    receive
	{udp, APISocket, _Ip, _Port, Bin} ->
            debug(3, "api server got UDP on ~p:~p~n", [_Ip, _Port]),
	    case (catch osc:decode(Bin)) of
		{bundle, Time, X} ->
                    debug("got bundle for time ~f~n", [Time]),
		    TagMap1 = do_bundle(TagMap, Time, X, CuePid),
		    ?MODULE:loop_api(APISocket, N, TagMap1, CuePid);
		{cmd, ["/flush", Tag]=Cmd} ->
		    debug_cmd(Cmd),
		    TagMap1 = flush_timers(Tag, all, TagMap),
		    ?MODULE:loop_api(APISocket, N, TagMap1, CuePid);
                {cmd, ["/internal-cue-port", Flag]=Cmd} ->
		    debug_cmd(Cmd),
                    CuePid ! {internal, Flag =:= 1},
		    ?MODULE:loop_api(APISocket, N+1, TagMap, CuePid);
                {cmd, ["/stop-start-cue-server", Flag]=Cmd} ->
		    debug_cmd(Cmd),
                    CuePid ! {enabled, Flag =:= 1},
                    ?MODULE:loop_api(APISocket, N+1, TagMap, CuePid);
		{cmd, Cmd} ->
                    log("Unknown command: \"~s\"~n", [Cmd]),
		    ?MODULE:loop_api(APISocket, N+1, TagMap, CuePid);
		{'EXIT', Why} ->
		    log("Error decoding: ~p ~p~n",[Bin, Why]),
		    ?MODULE:loop_api(APISocket, N+1, TagMap, CuePid)
	    end;
	Any ->
	    log("API Server got unexpected message: ~p~n", [Any]),
	    ?MODULE:loop_api(APISocket, N+1, TagMap, CuePid)
    after ?IDLE_TIME ->
	    debug(2, "api process idling; message count: ~p~n", [N]),
	    ?MODULE:loop_api(APISocket, N, TagMap, CuePid)
    end.

debug_cmd([Cmd|Args]) ->
    debug("command: ~s ~p~n", [Cmd, Args]).

do_bundle(TagMap, Time, [{_,B}], CuePid) ->
    {cmd, Cmd} = osc:decode(B),
    %% log("bundle cmd:~p~n",[Cmd]),
    case Cmd of
	["/send_after", Host, Port | Cmd1] ->
	    schedule_cmd("default", TagMap, Time, Host, Port, Cmd1, CuePid);
	["/send_after_tagged", Tag, Host, Port | Cmd1] ->
	    schedule_cmd(Tag, TagMap, Time, Host, Port, Cmd1, CuePid);
	_ ->
	    log("unexpected bundle:~p~n",[Cmd]),
	    TagMap
    end.

%% schedules a command for forwarding (or forwards immediately)

schedule_cmd(Tag, TagMap, Time, Host, Port, Cmd, CuePid) ->
    {Tracker, NewTagMap} = tracker_pid(Tag, TagMap),
    Data = {Host, Port, osc:encode(Cmd)},
    Delay = Time - osc:now(),
    MsDelay = trunc(Delay*1000+0.5), %% nearest
    if MsDelay > ?NODELAY_LIMIT ->
            Msg = {forward, Time, Data, Tracker},
            Timer = erlang:start_timer(MsDelay, CuePid, Msg),
            debug(2, "start timer of ~w ms for time ~f~n", [MsDelay, Time]),
            track_timer(Timer, Time, Tracker);
       true ->
            CuePid ! {forward, Time, Data},
            debug(2, "directly forward message for delay ~f~n", [Delay])
    end,
    NewTagMap.

%% Tracking Timers

%% Get the pid for the tag group tracker, creating it if needed
tracker_pid(Tag, TagMap) ->
    case maps:find(Tag, TagMap) of
	{ok, Pid} ->
            {Pid, TagMap};
	error ->
            Pid = spawn_link(fun() -> tracker(Tag) end),
            debug("start new tracker process for tag \"~s\"~n", [Tag]),
            {Pid, maps:put(Tag, Pid, TagMap)}
    end.

flush_timers(Tag, Which, TagMap) ->
    {Tracker, NewTagMap} = tracker_pid(Tag, TagMap),
    Tracker ! {flush, Which},
    NewTagMap.

track_timer(Timer, Time, Tracker) ->
    Tracker ! {track, Timer, Time}.

forget_timer(Timer, Tracker) ->
    Tracker ! {forget, Timer}.

%% Tracker process for a timer group - keeps a map of timer refs and
%% corresponding absolute times
tracker(Tag) ->
    tracker(Tag, #{}).

tracker(Tag, Map) ->
    receive
        {track, Ref, Time} ->
            debug(2, "track timer ~p for time ~f~n", [Ref, Time]),
            Map1 = Map#{Ref => Time},
            ?MODULE:tracker(Tag, Map1);
        {forget, Ref} ->
            debug(2, "forget timer ~p for time ~f~n",
                  [Ref, maps:get(Ref, Map)]),
            Map1 = maps:remove(Ref, Map),
            ?MODULE:tracker(Tag, Map1);
        {flush, all} ->
            debug("forget all timers tagged \"~s\" ~n", [Tag]),
            lists:foreach(fun (Ref) ->
                                  erlang:cancel_timer(Ref, [{async, true}])
                          end,
                          maps:keys(Map)),
            ?MODULE:tracker(Tag, #{});
        {flush, Time} ->
            %% flush all timers to trigger later than a specified time
            debug("forget timers tagged \"~s\" later than ~p ~n",
                  [Tag, Time]),
            Map1 = lists:foldl(
                     fun (R, M) ->
                             T = maps:get(R, M),
                             if T > Time ->
                                     erlang:cancel_timer(R, [{async, true}]),
                                     maps:remove(R, M);
                                true ->
                                     M
                             end
                     end,
                     maps:keys(Map),
                     Map),
            ?MODULE:tracker(Tag, Map1)
    end.
