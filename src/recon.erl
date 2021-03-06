%%% @author Fred Hebert <mononcqc@ferd.ca>
%%%  [http://ferd.ca/]
%%% @doc Recon, as a module, provides access to the high-level functionality
%%% contained in the Recon application.
%%%
%%% It has functions in five main categories:
%%%
%%% <dl>
%%%     <dt>1. State information</dt>
%%%     <dd>Process information is everything that has to do with the
%%%         general state of the node. Functions such as {@link info/1}
%%%         and {@link info/3} are wrappers to provide more details than
%%%         `erlang:process_info/2', while providing it in a production-safe
%%%         manner.</dd>
%%%     <dd>{@link proc_count/2} and {@link proc_window/3} are to be used
%%%         when you require information about processes in a larger sense:
%%%         biggest consumers of given process information (say memory or
%%%         reductions), either absolutely or over a sliding time window,
%%%         respectively.</dd>
%%%     <dd>{@link bin_leak/1} is a function that can be used to try and
%%%         see if your Erlang node is leaking refc binaries. See the function
%%%         itself for more details.</dd>
%%%     <dd>Functions to access node statistics, in a manner somewhat similar
%%%         to what <a href="https://github.com/ferd/vmstats">vmstats</a>
%%%         provides as a library. There are 3 of them:
%%%         {@link node_stats_print/2}, which displays them,
%%%         {@link node_stats_list/2}, which returns them in a list, and
%%%         {@link node_stats/4}, which provides a fold-like interface
%%%         for stats gathering.</dd>
%%%
%%%     <dt>2. OTP tools</dt>
%%%     <dd>This category provides tools to interact with pieces of OTP
%%%         more easily. At this point, the only function included is
%%%         {@link get_state/1}, which works as a wrapper around
%%%         `sys:get_state/1' in R16B01, and provides the required
%%%         functionality for older versions of Erlang.</dd>
%%%
%%%     <dt>3. Code Handling</dt>
%%%     <dd>Specific functions are in `recon' for the sole purpose
%%%         of interacting with source and compiled code.
%%%         {@link remote_load/1} and {@link remote_load/2} will allow
%%%         to take a local module, and load it remotely (in a diskless
%%%         manner) on another Erlang node you're connected to.</dd>
%%%     <dd>{@link source/1} allows to print the source of a loaded module,
%%%         in case it's not available in the currently running node.</dd>
%%%
%%%     <dt>4. Ports and Sockets</dt>
%%%     <dd>To make it simpler to debug some network-related issues,
%%%         recon contains functions to deal with Erlang ports (raw, file
%%%         handles, or inet). Functions {@link tcp/0}, {@link udp/0},
%%%         {@link sctp/0}, {@link files/0}, and {@link port_types/0} will
%%%         list all the Erlang ports of a given type. The latter function
%%%         prints counts of all individual types.</dd>
%%%     <dd>Finally, the functions {@link inet_count/2} and {@link inet_window/3}
%%%         provide the absolute or sliding window functionality of
%%%         {@link proc_count/2} and {@link proc_count/3} to inet ports
%%%         and connections currently on the node.</dd>
%%%
%%%     <dt>5. RPC</dt>
%%%     <dd>These are wrappers to make RPC work simpler with clusters of
%%%         Erlang nodes. Default RPC mechanisms (from the `rpc' module)
%%%         make it somewhat painful to call shell-defined funs over node
%%%         boundaries. The functions {@link rpc/1}, {@link rpc/2}, and
%%%         {@link rpc/3} will do it with a simpler interface.</dd>
%%%     <dd>Additionally, when you're running diagnostic code on remote
%%%         nodes and want to know which node evaluated what result, using
%%%         {@link named_rpc/1}, {@link named_rpc/2}, and {@link named_rpc/3}
%%%         will wrap the results in a tuple that tells you which node it's
%%%         coming from, making it easier to identify bad nodes.</dd>
%%% </dl>
%%% @end
-module(recon).
-export([info/1,info/3,
         proc_count/2, proc_window/3,
         bin_leak/1,
         node_stats_print/2, node_stats_list/2, node_stats/4]).
-export([get_state/1]).
-export([remote_load/1, remote_load/2,
         source/1]).
-export([tcp/0, udp/0, sctp/0, files/0, port_types/0,
         inet_count/2, inet_window/3]).
-export([rpc/1, rpc/2, rpc/3,
         named_rpc/1, named_rpc/2, named_rpc/3]).

%%%%%%%%%%%%%
%%% TYPES %%%
%%%%%%%%%%%%%
-type proc_attrs() :: {pid(),
                       Attr::_,
                       [Name::atom()
                       |{current_function, mfa()}
                       |{initial_call, mfa()}, ...]}.
-type inet_attrs() :: {port(),
                       Attr::_,
                       [{atom(), term()}]}.

-export_type([proc_attrs/0, inet_attrs/0]).
%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%

%%% Process Info %%%

%% @doc Equivalent to `info(<A.B.C>)' where `A', `B', and `C' are integers part
%% of a pid
-spec info(N,N,N) -> [{atom(), [{atom(),term()}]},...] when
      N :: non_neg_integer().
info(A,B,C) -> info(recon_lib:triple_to_pid(A,B,C)).

%% @doc Allows to be similar to `erlang:process_info/1', but excludes fields
%% such as the mailbox, which have a tendency to grow and be unsafe when called
%% in production systems. Also includes a few more fields than what is usually
%% given (`monitors', `monitored_by', etc.), and separates the fields in a more
%% readable format based on the type of information contained.
%%
%% Moreover, it will fetch and read information on local processes that were
%% registered locally (an atom), globally (`{global, Name}'), or through
%% another registry supported in the `{via, Module, Name}' syntax (must have a
%% `Module:whereis_name/1' function). Pids can also be passed in as a string
%% (`"<0.39.0>"') and will be converted to be used.
-spec info(Name) -> [{Type, [{Key, Value}]},...] when
      Name :: pid() | atom() | string()
           | {global, term()} | {via, module(), term()},
      Type :: meta | signals | location | memory | work,
      Key :: registered_name | dictionary | group_leader | status
           | links | monitors | monitored_by | trap_exit | initial_call
           | current_stacktrace | memory | message_queue_len | heap_size
           | total_heap_size | garbage_collection | reductions,
      Value :: term().
info(Name) when is_atom(Name) ->
    info(whereis(Name));
info(List = "<0."++_) ->
    info(list_to_pid(List));
info({global, Name}) ->
    info(global:whereis_name(Name));
info({via, Module, Name}) ->
    info(Module:whereis_name(Name));
info(Pid) when is_pid(Pid) ->
    Info = fun(List) -> erlang:process_info(Pid, List) end,
    [{meta, Info([registered_name, dictionary, group_leader, status])},
     {signals, Info([links, monitors, monitored_by, trap_exit])},
     {location, Info([initial_call, current_stacktrace])},
     {memory, Info([memory, message_queue_len, heap_size, total_heap_size,
                    garbage_collection])},
     {work, Info([reductions])}].

%% @doc Fetches a given attribute from all processes and returns
%% the biggest `Num' consumers.
%% @todo Implement this function so it only stores `Num' entries in
%% memory at any given time, instead of as many as there are
%% processes.
-spec proc_count(AttributeName, Num) -> [proc_attrs()] when
      AttributeName :: atom(),
      Num :: non_neg_integer().
proc_count(AttrName, Num) ->
    lists:sublist(lists:usort(
        fun({_,A,_},{_,B,_}) -> A > B end,
        recon_lib:proc_attrs(AttrName)
    ), Num).

%% @doc Fetches a given attribute from all processes and returns
%% the biggest entries, over a sliding time window.
%%
%% This function is particularly useful when processes on the node
%% are mostly short-lived, usually too short to inspect through other
%% tools, in order to figure out what kind of processes are eating
%% through a lot resources on a given node.
%%
%% It is important to see this function as a snapshot over a sliding
%% window. A program's timeline during sampling might look like this:
%%
%%  `--w---- [Sample1] ---x-------------y----- [Sample2] ---z--->'
%%
%% Some processes will live between `w' and die at `x', some between `y' and
%% `z', and some between `x' and `y'. These samples will not be too significant
%% as they're incomplete. If the majority of your processes run between a time
%% interval `x'...`y' (in absolute terms), you should make sure that your
%% sampling time is smaller than this so that for many processes, their
%% lifetime spans the equivalent of `w' and `z'. Not doing this can skew the
%% results: long-lived processes, that have 10 times the time to accumulate
%% data (say reductions) will look like bottlenecks when they're not one.
%%
%% Warning: this function depends on data gathered at two snapshots, and then
%% building a dictionary with entries to differentiate them. This can take a
%% heavy toll on memory when you have many dozens of thousands of processes.
-spec proc_window(AttributeName, Num, Milliseconds) -> [proc_attrs()] when
      AttributeName :: atom(),
      Num :: non_neg_integer(),
      Milliseconds :: pos_integer().
proc_window(AttrName, Num, Time) ->
    Sample = fun() -> recon_lib:proc_attrs(AttrName) end,
    {First,Last} = recon_lib:sample(Time, Sample),
    lists:sublist(lists:usort(
        fun({_,A,_},{_,B,_}) -> A > B end,
        recon_lib:sliding_window(First, Last)
    ), Num).

%% @doc Refc binaries can be leaking when barely-busy processes route them
%% around and do little else, or when extremely busy processes reach a stable
%% amount of memory allocated and do the vast majority of their work with refc
%% binaries. When this happens, it may take a very long while before references
%% get deallocated and refc binaries get to be garbage collected, leading to
%% Out Of Memory crashes.
%% This function fetches the number of refc binary references in each process
%% of the node, garbage collects them, and compares the resulting number of
%% references in each of them. The function then returns the `N' processes
%% that freed the biggest amount of binaries, potentially highlighting leaks.
%% 
%% See <a href="http://www.erlang.org/doc/efficiency_guide/binaryhandling.html#id65722">The efficiency guide</a>
%% for more details on refc binaries
-spec bin_leak(pos_integer()) -> [proc_attrs()].
bin_leak(N) ->
    lists:sublist(
        lists:usort(
            fun({K1,V1,_},{K2,V2,_}) -> {V1,K1} =< {V2,K2} end,
            [try
                {_,Pre,Id} = recon_lib:proc_attrs(binary, Pid),
                erlang:garbage_collect(Pid),
                {_,Post,_} = recon_lib:proc_attrs(binary, Pid),
                {Pid, length(Post)-length(Pre), Id}
            catch
                _:_ -> {Pid, 0}
            end || Pid <- processes()]),
        N).

%% @doc Shorthand for `node_stats(N, Interval, fun(X,_) -> io:format("~p~n",[X]) end, nostate)'.
-spec node_stats_print(Repeat, Interval) -> term() when
      Repeat :: non_neg_integer(),
      Interval :: pos_integer().
node_stats_print(N, Interval) ->
    node_stats(N, Interval, fun(X, _) -> io:format("~p~n",[X]) end, ok).

%% @doc Shorthand for `node_stats(N, Interval, fun(X,Acc) -> [X|Acc] end, [])'
%% with the results reversed to be in the right temporal order.
-spec node_stats_list(Repeat, Interval) -> [Stats] when
      Repeat :: non_neg_integer(),
      Interval :: pos_integer(),
      Stats :: {[Absolutes::{atom(),term()}],
                [Increments::{atom(),term()}]}.
node_stats_list(N, Interval) ->
    lists:reverse(node_stats(N, Interval, fun(X,Acc) -> [X|Acc] end, [])).

%% @doc Gathers statistics `N' time, waiting `Interval' milliseconds between
%% each run, and accumulates results using a folding function `FoldFun'.
%% The function will gather statistics in two forms: Absolutes and Increments.
%%
%% Absolutes are values that keep changing with time, and are useful to know
%% about as a datapoint: process count, size of the run queue, error_logger
%% queue length, and the memory of the node (total, processes, atoms, binaries,
%% and ets tables).
%%
%% Increments are values that are mostly useful when compared to a previous
%% one to have an idea what they're doing, because otherwise they'd never
%% stop increasing: bytes in and out of the node, number of garbage colelctor
%% runs, words of memory that were garbage collected, and the global reductions
%% count for the node.
-spec node_stats(N, Interval, FoldFun, Acc) -> Acc when
      N :: non_neg_integer(),
      Interval :: pos_integer(),
      FoldFun :: fun((Stats, Acc) -> Acc),
      Acc :: term(),
      Stats :: {[Absolutes::{atom(),term()}],
                [Increments::{atom(),term()}]}.
node_stats(N, Interval, FoldFun, Init) ->
    %% Stats is an ugly fun, but it does its thing.
    Stats = fun({{OldIn,OldOut},{OldGCs,OldWords,_}}) ->
        %% Absolutes
        ProcC = erlang:system_info(process_count),
        RunQ = erlang:statistics(run_queue),
        {_,LogQ} = process_info(whereis(error_logger),  message_queue_len),
        %% Mem (Absolutes)
        Mem = erlang:memory(),
        Tot = proplists:get_value(total, Mem),
        ProcM = proplists:get_value(processes_used,Mem),
        Atom = proplists:get_value(atom_used,Mem),
        Bin = proplists:get_value(binary, Mem),
        Ets = proplists:get_value(ets, Mem),
        %% Incremental
        {{input,In},{output,Out}} = erlang:statistics(io),
        GC={GCs,Words,_} = erlang:statistics(garbage_collection),
        BytesIn = In-OldIn,
        BytesOut = Out-OldOut,
        GCCount = GCs-OldGCs,
        GCWords = Words-OldWords,
        {_, Reds} = erlang:statistics(reductions),
         %% Stats Results
        {{[{process_count,ProcC}, {run_queue,RunQ},
           {error_logger_queue_len,LogQ}, {memory_total,Tot},
           {memory_procs,ProcM}, {memory_atoms,Atom},
           {memory_bin,Bin}, {memory_ets,Ets}],
          [{bytes_in,BytesIn}, {bytes_out,BytesOut},
           {gc_count,GCCount}, {gc_words_reclaimed,GCWords},
           {reductions,Reds}]},
         %% New State
         {{In,Out}, GC}}
    end,
    {{input,In},{output,Out}} = erlang:statistics(io),
    Gc = erlang:statistics(garbage_collection),
    recon_lib:time_fold(N, Interval, Stats, {{In,Out}, Gc}, FoldFun, Init).

%%% OTP & Manipulations %%%

%% @doc Fetch the internal state of an OTP process.
%% Calls `sys:get_state/1' directly in R16B01+, and fetches
%% it dynamically on older versions of OTP.
-spec get_state(Name) -> term() when
      Name :: pid() | atom() | {global, term()} | {via, module(), term()}.
get_state(Proc) ->
    try 
        sys:get_state(Proc)
    catch
        error:undef ->
            case sys:get_status(Proc) of
                {status,_Pid,{module,gen_server},Data} ->
                    {data, Props} = lists:last(lists:nth(5, Data)),
                    proplists:get_value("State", Props);
                {status,_Pod,{module,gen_fsm},Data} ->
                    {data, Props} = lists:last(lists:nth(5, Data)),
                    proplists:get_value("StateData", Props)
            end
    end.

%%% Code & Stuff %%%

%% @doc Equivalent to `remote_load(nodes(), Mod)'.
-spec remote_load(module()) -> term().
remote_load(Mod) -> remote_load(nodes(), Mod).

%% @doc Loads one or more modules remotely, in a diskless manner.  Allows to
%% share code loaded locally with a remote node that doesn't have it
-spec remote_load(Nodes, module()) -> term() when
      Nodes :: [node(),...] | node().
remote_load(Nodes=[_|_], Mod) when is_atom(Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod), 
    rpc:multicall(Nodes, code, load_binary, [Mod, File, Bin]);
remote_load(Nodes=[_|_], Modules) when is_list(Modules) ->
    [remote_load(Nodes, Mod) || Mod <- Modules];
remote_load(Node, Mod) ->
    remote_load([Node], Mod).

%% @doc Obtain the source code of a module compiled with `debug_info'.
%% The returned list sadly does not allow to format the types and typed
%% records the way they look in the original module, but instead goes to
%% an intermediary form used in the AST. They will still be placed
%% in the right module attributes, however.
%% @todo Figure out a way to pretty-print typespecs and records.
-spec source(module()) -> iolist().
source(Module) ->
    Path = code:which(Module),
    {ok,{_,[{abstract_code,{_,AC}}]}} = beam_lib:chunks(Path, [abstract_code]),
    erl_prettypr:format(erl_syntax:form_list(AC)).

%%% Ports Info %%%

%% @doc returns a list of all TCP ports (the data type) open on the node.
-spec tcp() -> [port()].
tcp() -> recon_lib:port_list(name, "tcp_inet").

%% @doc returns a list of all UDP ports (the data type) open on the node.
-spec udp() -> [port()].
udp() -> recon_lib:port_list(name, "udp_inet").

%% @doc returns a list of all SCTP ports (the data type) open on the node.
-spec sctp() -> [port()].
sctp() -> recon_lib:port_list(name, "sctp_inet").

%% @doc returns a list of all file handles open on the node.
-spec files() -> [port()].
files() -> recon_lib:port_list(name, "efile").

%% @doc Shows a list of all different ports on the node with their respective
%% types.
-spec port_types() -> [{pos_integer(),Type::string()}].
port_types() ->
    lists:usort(
        %% sorts by biggest count, smallest type
        fun({KA,VA}, {KB,VB}) -> {VA,KB} > {VB,KA} end,
        recon_lib:count([Name || {_, Name} <- recon_lib:port_list(name)])
    ).

%% @doc Fetches a given attribute from all inet ports (TCP, UDP, SCTP)
%% and returns the biggest `Num' consumers.
%%
%% The values to be used can be the number of octets (bytes) sent, received,
%% or both (`send_oct', `recv_oct', `oct', respectively), or the number
%% of packets sent, received, or both (`send_cnt', `recv_cnt', `cnt',
%% respectively). Individual absolute values for each metric will be returned
%% in the 3rd position of the resulting tuple.
%%
%% @todo Implement this function so it only stores `Num' entries in
%% memory at any given time, instead of as many as there are
%% processes.
-spec inet_count(AttributeName, Num) -> [inet_attrs()] when
      AttributeName :: 'recv_cnt' | 'recv_oct' | 'send_cnt' | 'send_oct'
                     | 'cnt' | 'oct',
      Num :: non_neg_integer().
inet_count(Attr, Num) ->
    lists:sublist(lists:usort(
        fun({_,A,_},{_,B,_}) -> A > B end,
        recon_lib:inet_attrs(Attr)
    ), Num).

%% @doc Fetches a given attribute from all inet ports (TCP, UDP, SCTP)
%% and returns the biggest entries, over a sliding time window.
%%
%% Warning: this function depends on data gathered at two snapshots, and then
%% building a dictionary with entries to differentiate them. This can take a
%% heavy toll on memory when you have many dozens of thousands of ports open.
%%
%% The values to be used can be the number of octets (bytes) sent, received,
%% or both (`send_oct', `recv_oct', `oct', respectively), or the number
%% of packets sent, received, or both (`send_cnt', `recv_cnt', `cnt',
%% respectively). Individual absolute values for each metric will be returned
%% in the 3rd position of the resulting tuple.
-spec inet_window(AttributeName, Num, Milliseconds) -> [inet_attrs()] when
      AttributeName :: 'recv_cnt' | 'recv_oct' | 'send_cnt' | 'send_oct'
                     | 'cnt' | 'oct',
      Num :: non_neg_integer(),
      Milliseconds :: pos_integer().
inet_window(Attr, Num, Time) when is_atom(Attr) ->
    Sample = fun() -> recon_lib:inet_attrs(Attr) end,
    {First,Last} = recon_lib:sample(Time, Sample),
    lists:sublist(lists:usort(
        fun({_,A,_},{_,B,_}) -> A > B end,
        recon_lib:sliding_window(First, Last)
    ), Num).


%%% RPC Utils %%%

%% @doc Shorthand for `rpc([node()|nodes()], Fun)'.
-spec rpc(fun(() -> term())) -> {[Success::_],[Fail::_]}.
rpc(Fun) ->
    rpc([node()|nodes()], Fun).

%% @doc Shorthand for `rpc(Nodes, Fun, infinity)'.
-spec rpc(node()|[node(),...], fun(() -> term())) -> {[Success::_],[Fail::_]}.
rpc(Nodes, Fun) ->
    rpc(Nodes, Fun, infinity).

%% @doc Runs an arbitrary fun (of arity 0) over one or more nodes.
-spec rpc(node()|[node(),...], fun(() -> term()), timeout()) -> {[Success::_],[Fail::_]}.
rpc(Nodes=[_|_], Fun, Timeout) when is_function(Fun,0) ->
    rpc:multicall(Nodes, erlang, apply, [Fun,[]], Timeout);
rpc(Node, Fun, Timeout) when is_atom(Node) ->
    rpc([Node], Fun, Timeout).

%% @doc Shorthand for `named_rpc([node()|nodes()], Fun)'.
-spec named_rpc(fun(() -> term())) -> {[Success::_],[Fail::_]}.
named_rpc(Fun) ->
    named_rpc([node()|nodes()], Fun).

%% @doc Shorthand for `named_rpc(Nodes, Fun, infinity)'.
-spec named_rpc(node()|[node(),...], fun(() -> term())) -> {[Success::_],[Fail::_]}.
named_rpc(Nodes, Fun) ->
    named_rpc(Nodes, Fun, infinity).

%% @doc Runs an arbitrary fun (of arity 0) over one or more nodes, and returns the
%% name of the node that computed a given result along with it, in a tuple.
-spec named_rpc(node()|[node(),...], fun(() -> term()), timeout()) -> {[Success::_],[Fail::_]}.
named_rpc(Nodes=[_|_], Fun, Timeout) when is_function(Fun,0) ->
    rpc:multicall(Nodes, erlang, apply, [fun() -> {node(),Fun()} end,[]], Timeout);
named_rpc(Node, Fun, Timeout) when is_atom(Node) ->
    named_rpc([Node], Fun, Timeout).

