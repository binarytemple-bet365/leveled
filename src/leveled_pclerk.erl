%% Controlling asynchronous work in leveleddb to manage compaction within a
%% level and cleaning out of old files across a level


-module(leveled_pclerk).

-behaviour(gen_server).

-include("../include/leveled.hrl").

-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        clerk_new/1,
        clerk_prompt/2,
        clerk_stop/1,
        code_change/3,
        perform_merge/4]).      

-include_lib("eunit/include/eunit.hrl").

-define(INACTIVITY_TIMEOUT, 2000).
-define(HAPPYTIME_MULTIPLIER, 5).

-record(state, {owner :: pid()}).

%%%============================================================================
%%% API
%%%============================================================================

clerk_new(Owner) ->
    {ok, Pid} = gen_server:start(?MODULE, [], []),
    ok = gen_server:call(Pid, {register, Owner}, infinity),
    {ok, Pid}.
    
clerk_prompt(Pid, penciller) ->
    gen_server:cast(Pid, penciller_prompt),
    ok.

clerk_stop(Pid) ->
    gen_server:cast(Pid, stop).

%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

init([]) ->
    {ok, #state{}}.

handle_call({register, Owner}, _From, State) ->
    {reply, ok, State#state{owner=Owner}, ?INACTIVITY_TIMEOUT}.

handle_cast(penciller_prompt, State) ->
    Timeout = requestandhandle_work(State),
    {noreply, State, Timeout};
handle_cast(stop, State) ->
    {stop, normal, State}.

handle_info(timeout, State) ->
    %% The pcl prompt will cause a penciller_prompt, to re-trigger timeout
    case leveled_penciller:pcl_prompt(State#state.owner) of
        ok ->
            {noreply, State};
        pause ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%============================================================================
%%% Internal functions
%%%============================================================================

requestandhandle_work(State) ->
    case leveled_penciller:pcl_workforclerk(State#state.owner) of
        {none, Backlog} ->
            io:format("Work prompted but none needed~n"),
            case Backlog of
                false ->
                    ?INACTIVITY_TIMEOUT * ?HAPPYTIME_MULTIPLIER;
                _ ->
                    ?INACTIVITY_TIMEOUT
            end;
        {WI, _} ->
            {NewManifest, FilesToDelete} = merge(WI),
            UpdWI = WI#penciller_work{new_manifest=NewManifest,
                                        unreferenced_files=FilesToDelete},
            R = leveled_penciller:pcl_requestmanifestchange(State#state.owner,
                                                                UpdWI),
            case R of
                ok ->
                    %% Request for manifest change must be a synchronous call
                    %% Otherwise cannot mark files for deletion (may erase
                    %% without manifest change on close)
                    mark_for_delete(FilesToDelete, State#state.owner),
                    ?INACTIVITY_TIMEOUT;
                _ ->
                    %% New files will forever remain in an undetermined state
                    %% The disconnected files should be logged at start-up for
                    %% Manual clear-up
                    ?INACTIVITY_TIMEOUT
            end
    end.    


merge(WI) ->
    SrcLevel = WI#penciller_work.src_level,
    {SrcF, UpdMFest1} = select_filetomerge(SrcLevel,
                                                WI#penciller_work.manifest),
    SinkFiles = get_item(SrcLevel + 1, UpdMFest1, []),
    Splits = lists:splitwith(fun(Ref) ->
                                case {Ref#manifest_entry.start_key,
                                     Ref#manifest_entry.end_key} of
                                 {_, EK} when SrcF#manifest_entry.start_key > EK ->
                                     false;
                                 {SK, _} when SrcF#manifest_entry.end_key < SK ->
                                     false;
                                 _ ->
                                     true
                                end end,
                            SinkFiles),
    {Candidates, Others} = Splits,
    
    %% TODO:
    %% Need to work out if this is the top level
    %% And then tell merge process to create files at the top level
    %% Which will include the reaping of expired tombstones
    io:format("Merge from level ~w to merge into ~w files below~n",
                [SrcLevel, length(Candidates)]),
     
    MergedFiles = case length(Candidates) of
        0 ->
            %% If no overlapping candiates, manifest change only required
            %%
            %% TODO: need to think still about simply renaming when at 
            %% lower level
            io:format("File ~s to simply switch levels to level ~w~n",
                        [SrcF#manifest_entry.filename, SrcLevel + 1]),
            [SrcF];
        _ ->
            perform_merge({SrcF#manifest_entry.owner,
                            SrcF#manifest_entry.filename},
                            Candidates,
                            SrcLevel,
                            {WI#penciller_work.ledger_filepath,
                                WI#penciller_work.next_sqn})
    end,  
    case MergedFiles of
        error ->
            merge_failure;
        _ ->
            NewLevel = lists:sort(lists:append(MergedFiles, Others)),
            UpdMFest2 = lists:keystore(SrcLevel + 1,
                                        1,
                                        UpdMFest1,
                                        {SrcLevel + 1, NewLevel}),
            
            ok = filelib:ensure_dir(WI#penciller_work.manifest_file),
            {ok, Handle} = file:open(WI#penciller_work.manifest_file,
                                        [binary, raw, write]),
            ok = file:write(Handle, term_to_binary(UpdMFest2)),
            ok = file:close(Handle),
            case lists:member(SrcF, MergedFiles) of
                true ->
                    {UpdMFest2, Candidates};
                false ->
                    %% Can rub out src file as it is not part of output
                    {UpdMFest2, Candidates ++ [SrcF]}
            end
    end.
    

mark_for_delete([], _Penciller) ->
    ok;
mark_for_delete([Head|Tail], Penciller) ->
    leveled_sft:sft_setfordelete(Head#manifest_entry.owner, Penciller),
    mark_for_delete(Tail, Penciller).
    
        
            
%% An algorithm for discovering which files to merge ....
%% We can find the most optimal file:
%% - The one with the most overlapping data below?
%% - The one that overlaps with the fewest files below?
%% - The smallest file?
%% We could try and be fair in some way (merge oldest first)
%% Ultimately, there is alack of certainty that being fair or optimal is
%% genuinely better - ultimately every file has to be compacted.
%%
%% Hence, the initial implementation is to select files to merge at random

select_filetomerge(SrcLevel, Manifest) ->
    {SrcLevel, LevelManifest} = lists:keyfind(SrcLevel, 1, Manifest),
    Selected = lists:nth(random:uniform(length(LevelManifest)),
                            LevelManifest),
    UpdManifest = lists:keyreplace(SrcLevel,
                                    1,
                                    Manifest,
                                    {SrcLevel,
                                        lists:delete(Selected,
                                                        LevelManifest)}),
    {Selected, UpdManifest}.
    
    

%% Assumption is that there is a single SFT from a higher level that needs
%% to be merged into multiple SFTs at a lower level.  This should create an
%% entirely new set of SFTs, and the calling process can then update the
%% manifest.
%%
%% Once the FileToMerge has been emptied, the remainder of the candidate list
%% needs to be placed in a remainder SFT that may be of a sub-optimal (small)
%% size.  This stops the need to perpetually roll over the whole level if the
%% level consists of already full files.  Some smartness may be required when
%% selecting the candidate list so that small files just outside the candidate
%% list be included to avoid a proliferation of small files.
%%
%% FileToMerge should be a tuple of {FileName, Pid} where the Pid is the Pid of
%% the gen_server leveled_sft process representing the file.
%%
%% CandidateList should be a list of {StartKey, EndKey, Pid} tuples
%% representing different gen_server leveled_sft processes, sorted by StartKey.
%%
%% The level is the level which the new files should be created at.

perform_merge({UpperSFTPid, Filename}, CandidateList, Level, {Filepath, MSN}) ->
    io:format("Merge to be commenced for FileToMerge=~s with MSN=~w~n",
                    [Filename, MSN]),
    PointerList = lists:map(fun(P) ->
                                {next, P#manifest_entry.owner, all} end,
                            CandidateList),
    do_merge([{next, UpperSFTPid, all}],
                    PointerList, Level, {Filepath, MSN}, 0, []).

do_merge([], [], Level, {_Filepath, MSN}, FileCounter, OutList) ->
    io:format("Merge completed with MSN=~w Level=~w and FileCounter=~w~n",
                [MSN, Level, FileCounter]),
    OutList;
do_merge(KL1, KL2, Level, {Filepath, MSN}, FileCounter, OutList) ->
    FileName = lists:flatten(io_lib:format(Filepath ++ "_~w_~w.sft",
                                            [Level + 1, FileCounter])),
    io:format("File to be created as part of MSN=~w Filename=~s~n",
                [MSN, FileName]),
    TS1 = os:timestamp(),
    case leveled_sft:sft_new(FileName, KL1, KL2, Level + 1) of
        {ok, _Pid, {error, Reason}} ->
            io:format("Exiting due to error~w~n", [Reason]),
            error;
        {ok, Pid, Reply} ->
            {{KL1Rem, KL2Rem}, SmallestKey, HighestKey} = Reply,
            ExtMan = lists:append(OutList,
                                    [#manifest_entry{start_key=SmallestKey,
                                                        end_key=HighestKey,
                                                        owner=Pid,
                                                        filename=FileName}]),
            MTime = timer:now_diff(os:timestamp(), TS1),
            io:format("File creation took ~w microseconds ~n", [MTime]),
            do_merge(KL1Rem, KL2Rem, Level, {Filepath, MSN},
                            FileCounter + 1, ExtMan)
    end.


get_item(Index, List, Default) ->
    case lists:keysearch(Index, 1, List) of
        {value, {Index, Value}} ->
            Value;
        false ->
            Default
    end.


%%%============================================================================
%%% Test
%%%============================================================================


generate_randomkeys(Count, BucketRangeLow, BucketRangeHigh) ->
    generate_randomkeys(Count, [], BucketRangeLow, BucketRangeHigh).

generate_randomkeys(0, Acc, _BucketLow, _BucketHigh) ->
    Acc;
generate_randomkeys(Count, Acc, BucketLow, BRange) ->
    BNumber = string:right(integer_to_list(BucketLow + random:uniform(BRange)),
                                            4, $0),
    KNumber = string:right(integer_to_list(random:uniform(1000)), 4, $0),
    RandKey = {{o,
                "Bucket" ++ BNumber,
                "Key" ++ KNumber},
                {Count + 1,
                {active, infinity}, null}},
    generate_randomkeys(Count - 1, [RandKey|Acc], BucketLow, BRange).

choose_pid_toquery([ManEntry|_T], Key) when
                        Key >= ManEntry#manifest_entry.start_key,
                        ManEntry#manifest_entry.end_key >= Key ->
    ManEntry#manifest_entry.owner;
choose_pid_toquery([_H|T], Key) ->
    choose_pid_toquery(T, Key).


find_randomkeys(_FList, 0, _Source) ->
    ok;
find_randomkeys(FList, Count, Source) ->
    KV1 = lists:nth(random:uniform(length(Source)), Source),
    K1 = leveled_bookie:strip_to_keyonly(KV1),
    P1 = choose_pid_toquery(FList, K1),
    FoundKV = leveled_sft:sft_get(P1, K1),
    Check = case FoundKV of
                not_present ->
                    io:format("Failed to find ~w in ~w~n", [K1, P1]),
                    error;
                _ ->
                    Found = leveled_bookie:strip_to_keyonly(FoundKV),
                    io:format("success finding ~w in ~w~n", [K1, P1]),
                    ?assertMatch(K1, Found),
                    ok
            end,
    ?assertMatch(Check, ok),
    find_randomkeys(FList, Count - 1, Source).


merge_file_test() ->
    KL1_L1 = lists:sort(generate_randomkeys(16000, 0, 1000)),
    {ok, PidL1_1, _} = leveled_sft:sft_new("../test/KL1_L1.sft",
                                            KL1_L1, [], 1),
    KL1_L2 = lists:sort(generate_randomkeys(16000, 0, 250)),
    {ok, PidL2_1, _} = leveled_sft:sft_new("../test/KL1_L2.sft",
                                            KL1_L2, [], 2),
    KL2_L2 = lists:sort(generate_randomkeys(16000, 250, 250)),
    {ok, PidL2_2, _} = leveled_sft:sft_new("../test/KL2_L2.sft",
                                            KL2_L2, [], 2),
    KL3_L2 = lists:sort(generate_randomkeys(16000, 500, 250)),
    {ok, PidL2_3, _} = leveled_sft:sft_new("../test/KL3_L2.sft",
                                            KL3_L2, [], 2),
    KL4_L2 = lists:sort(generate_randomkeys(16000, 750, 250)),
    {ok, PidL2_4, _} = leveled_sft:sft_new("../test/KL4_L2.sft",
                                            KL4_L2, [], 2),
    Result = perform_merge({PidL1_1, "../test/KL1_L1.sft"},
                            [#manifest_entry{owner=PidL2_1},
                                #manifest_entry{owner=PidL2_2},
                                #manifest_entry{owner=PidL2_3},
                                #manifest_entry{owner=PidL2_4}],
                            2, {"../test/", 99}),
    lists:foreach(fun(ManEntry) ->
                        {o, B1, K1} = ManEntry#manifest_entry.start_key,
                        {o, B2, K2} = ManEntry#manifest_entry.end_key,
                        io:format("Result of ~s ~s and ~s ~s with Pid ~w~n",
                            [B1, K1, B2, K2, ManEntry#manifest_entry.owner]) end,
                        Result),
    io:format("Finding keys in KL1_L1~n"),
    ok = find_randomkeys(Result, 50, KL1_L1),
    io:format("Finding keys in KL1_L2~n"),
    ok = find_randomkeys(Result, 50, KL1_L2),
    io:format("Finding keys in KL2_L2~n"),
    ok = find_randomkeys(Result, 50, KL2_L2),
    io:format("Finding keys in KL3_L2~n"),
    ok = find_randomkeys(Result, 50, KL3_L2),
    io:format("Finding keys in KL4_L2~n"),
    ok = find_randomkeys(Result, 50, KL4_L2),
    leveled_sft:sft_clear(PidL1_1),
    leveled_sft:sft_clear(PidL2_1),
    leveled_sft:sft_clear(PidL2_2),
    leveled_sft:sft_clear(PidL2_3),
    leveled_sft:sft_clear(PidL2_4),
    lists:foreach(fun(ManEntry) ->
                    leveled_sft:sft_clear(ManEntry#manifest_entry.owner) end,
                    Result).


select_merge_file_test() ->
    L0 = [{{o, "B1", "K1"}, {o, "B3", "K3"}, dummy_pid}],
    L1 = [{{o, "B1", "K1"}, {o, "B2", "K2"}, dummy_pid},
            {{o, "B2", "K3"}, {o, "B4", "K4"}, dummy_pid}],
    Manifest = [{0, L0}, {1, L1}],
    {FileRef, NewManifest} = select_filetomerge(0, Manifest),
    ?assertMatch(FileRef, {{o, "B1", "K1"}, {o, "B3", "K3"}, dummy_pid}),
    ?assertMatch(NewManifest, [{0, []}, {1, L1}]).