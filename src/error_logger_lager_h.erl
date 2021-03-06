%% Copyright (c) 2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% @doc A error_logger backend for redirecting events into lager.
%% Error messages and crash logs are also optionally written to a crash log.

%% @see lager_crash_log

%% @private

-module(error_logger_lager_h).

-include("lager.hrl").

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-export([format_reason/1]).

-define(LOG(Level, Pid, Msg),
    case ?SHOULD_LOG(Level) of
        true ->
            lager:log(Level, Pid, Msg);
        _ -> ok
    end).

-define(LOG(Level, Pid, Fmt, Args),
    case ?SHOULD_LOG(Level) of
        true ->
            lager:log(Level, Pid, Fmt, Args);
        _ -> ok
    end).

-define(CRASH_LOG(Event),
    gen_server:cast(lager_crash_log, {log, Event})).

-spec init(any()) -> {ok, {}}.
init(_) ->
    {ok, {}}.

handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event(Event, State) ->
    case Event of
        {error, _GL, {Pid, Fmt, Args}} ->
            case Fmt of
                "** Generic server "++_ ->
                    %% gen_server terminate
                    [Name, _Msg, _State, Reason] = Args,
                    ?CRASH_LOG(Event),
                    ?LOG(error, Pid, "gen_server ~w terminated with reason: ~s",
                        [Name, format_reason(Reason)]);
                "** State machine "++_ ->
                    %% gen_fsm terminate
                    [Name, _Msg, StateName, _StateData, Reason] = Args,
                    ?CRASH_LOG(Event),
                    ?LOG(error, Pid, "gen_fsm ~w in state ~w terminated with reason: ~s",
                        [Name, StateName, format_reason(Reason)]);
                "** gen_event handler"++_ ->
                    %% gen_event handler terminate
                    [ID, Name, _Msg, _State, Reason] = Args,
                    ?CRASH_LOG(Event),
                    ?LOG(error, Pid, "gen_event ~w installed in ~w terminated with reason: ~s",
                        [ID, Name, format_reason(Reason)]);
                _ ->
                    ?CRASH_LOG(Event),
                    ?LOG(error, Pid, lager_trunc_io:format(Fmt, Args, 4096))
            end;
        {error_report, _GL, {Pid, std_error, D}} ->
            ?CRASH_LOG(Event),
            ?LOG(error, Pid, print_silly_list(D));
        {error_report, _GL, {Pid, supervisor_report, D}} ->
            ?CRASH_LOG(Event),
            case lists:sort(D) of
                [{errorContext, Ctx}, {offender, Off}, {reason, Reason}, {supervisor, Name}] ->
                    Offender = format_offender(Off),
                    ?LOG(error, Pid, "Supervisor ~w had child ~s exit with reason ~s in context ~w", [element(2, Name), Offender, format_reason(Reason), Ctx]);
                _ ->
                    ?LOG(error, Pid, ["SUPERVISOR REPORT ", print_silly_list(D)])
            end;
        {error_report, _GL, {Pid, crash_report, [Self, Neighbours]}} ->
            ?CRASH_LOG(Event),
            ?LOG(error, Pid, ["CRASH REPORT ", format_crash_report(Self, Neighbours)]);
        {warning_msg, _GL, {Pid, Fmt, Args}} ->
            ?LOG(warning, Pid, lager_trunc_io:format(Fmt, Args, 4096));
        {warning_report, _GL, {Pid, std_warning, Report}} ->
            ?LOG(warning, Pid, print_silly_list(Report));
        {info_msg, _GL, {Pid, Fmt, Args}} ->
            ?LOG(info, Pid, lager_trunc_io:format(Fmt, Args, 4096));
        {info_report, _GL, {Pid, std_info, D}} when is_list(D) ->
            Details = lists:sort(D),
            case Details of
                [{application, App}, {exited, Reason}, {type, _Type}] ->
                    ?LOG(info, Pid, "Application ~w exited with reason: ~w", [App, Reason]);
                _ ->
                    ?LOG(info, Pid, print_silly_list(D))
            end;
        {info_report, _GL, {Pid, std_info, D}} ->
            ?LOG(info, Pid, "~w", [D]);
        {info_report, _GL, {P, progress, D}} ->
            Details = lists:sort(D),
            case Details of
                [{application, App}, {started_at, Node}] ->
                    ?LOG(info, P, "Application ~w started on node ~w",
                        [App, Node]);
                [{started, Started}, {supervisor, Name}] ->
                    MFA = format_mfa(proplists:get_value(mfargs, Started)),
                    Pid = proplists:get_value(pid, Started),
                    ?LOG(debug, P, "Supervisor ~w started ~s at pid ~w", [element(2, Name), MFA, Pid]);
                _ ->
                    ?LOG(info, P, ["PROGRESS REPORT ", print_silly_list(D)])
            end;
        _ ->
            ?LOG(warning, self(), "Unexpected error_logger event ~w", [Event])
    end,
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal functions

format_crash_report(Report, Neighbours) ->
    Name = proplists:get_value(registered_name, Report, proplists:get_value(pid, Report)),
    {_Class, Reason, _Trace} = proplists:get_value(error_info, Report),
    io_lib:format("Process ~w with ~w neighbours crashed with reason: ~s", [Name, length(Neighbours), format_reason(Reason)]).

format_offender(Off) ->
    case proplists:get_value(name, Off) of
        undefined ->
            %% supervisor_bridge
            io_lib:format("at module ~w at ~w", [proplists:get_value(mod, Off), proplists:get_value(pid, Off)]);
        Name ->
            %% regular supervisor
            MFA = format_mfa(proplists:get_value(mfargs, Off)),
            io_lib:format("~w started with ~s at ~w", [Name, MFA, proplists:get_value(pid, Off)])
    end.

format_reason({'function not exported', [{M, F, A},MFA|_]}) ->
    ["call to undefined function ", format_mfa({M, F, length(A)}), " from ", format_mfa(MFA)];
format_reason({undef, [MFA|_]}) ->
    ["call to undefined function ", format_mfa(MFA)];
format_reason({bad_return_value, Val}) ->
    io_lib:format("bad return value: ~w", [Val]);
format_reason({{case_clause, Val}, [MFA|_]}) ->
    [io_lib:format("no case clause matching ~w in ", [Val]), format_mfa(MFA)];
format_reason({function_clause, [MFA|_]}) ->
    ["no function clause matching ", format_mfa(MFA)];
format_reason({if_clause, [MFA|_]}) ->
    ["no true branch found while evaluating if expression in ", format_mfa(MFA)];
format_reason({{try_clause, Val}, [MFA|_]}) ->
    [io_lib:format("no try clause matching ~w in ", [Val]), format_mfa(MFA)]; 
format_reason({badarith, [MFA|_]}) ->
    ["bad arithmetic expression in ", format_mfa(MFA)];
format_reason({{badmatch, Val}, [MFA|_]}) ->
    [io_lib:format("no match of right hand value ~w in ", [Val]), format_mfa(MFA)];
format_reason({emfile, _Trace}) ->
    "maximum number of file descriptors exhausted, check ulimit -n";
format_reason({system_limit, [{M, F, _}|_] = Trace}) ->
    Limit = case {M, F} of
        {erlang, open_port} ->
            "maximum number of ports exceeded";
        {erlang, spawn} ->
            "maximum number of processes exceeded";
        {erlang, spawn_opt} ->
            "maximum number of processes exceeded";
        {erlang, list_to_atom} ->
            "tried to create an atom larger than 255, or maximum atom count exceeded";
        {ets, new} ->
            "maximum number of ETS tables exceeded";
        _ ->
            {Str, _} = lager_trunc_io:print(Trace, 500),
            Str
    end,
    ["system limit: ", Limit];
format_reason({badarg, [MFA,MFA2|_]}) ->
    case MFA of
        {_M, _F, A} when is_list(A) ->
            ["bad argument in call to ", format_mfa(MFA), " in ", format_mfa(MFA2)];
        _ ->
            %% seems to be generated by a bad call to a BIF
            ["bad argument in ", format_mfa(MFA)]
    end;
format_reason({{badarity, {Fun, Args}}, [MFA|_]}) ->
    {arity, Arity} = lists:keyfind(arity, 1, erlang:fun_info(Fun)),
    [io_lib:format("fun called with wrong arity of ~w instead of ~w in ", [length(Args), Arity]), format_mfa(MFA)];
format_reason({noproc, MFA}) ->
    ["no such process or port in call to ", format_mfa(MFA)];
format_reason({{badfun, Term}, [MFA|_]}) ->
    [io_lib:format("bad function ~w in ", [Term]), format_mfa(MFA)];
format_reason(Reason) ->
    {Str, _} = lager_trunc_io:print(Reason, 500),
    Str.

format_mfa({M, F, A}) when is_list(A) ->
    io_lib:format("~w:~w("++format_args(A, [])++")", [M, F | A]);
format_mfa({M, F, A}) when is_integer(A) ->
    io_lib:format("~w:~w/~w", [M, F, A]);
format_mfa(Other) ->
    io_lib:format("~w", [Other]).

format_args([], Acc) ->
    string:join(lists:reverse(Acc), ", ");
format_args([H|T], Acc) when is_list(H) ->
    case lager_stdlib:string_p(H) of
        true ->
            format_args(T, ["\"~s\""|Acc]);
        _ ->
            format_args(T, ["~w"|Acc])
    end;
format_args([_|T], Acc) ->
    format_args(T, ["~w"|Acc]).

print_silly_list(L) when is_list(L) ->
    case lager_stdlib:string_p(L) of
        true ->
            lager_trunc_io:format("~s", [L], 4096);
        _ ->
            print_silly_list(L, [], [])
    end;
print_silly_list(L) ->
    {Str, _} = lager_trunc_io:print(L, 4096),
    Str.

print_silly_list([], Fmt, Acc) ->
    lager_trunc_io:format(string:join(lists:reverse(Fmt), ", "),
        lists:reverse(Acc), 4096);
print_silly_list([{K,V}|T], Fmt, Acc) ->
    print_silly_list(T, ["~w: ~w" | Fmt], [V, K | Acc]);
print_silly_list([H|T], Fmt, Acc) ->
    print_silly_list(T, ["~w" | Fmt], [H | Acc]).
