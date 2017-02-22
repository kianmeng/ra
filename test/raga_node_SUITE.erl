-module(raga_node_SUITE).

-compile(export_all).

-include("raga.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [
     election_timeout,
     quorum,
     follower_vote,
     follower_append_entries
    ].

follower_append_entries(_Config) ->
    State = (base_state(3))#{commit_index => 1},
    EmptyAE = #append_entries_rpc{term = 5,
                                  leader_id = n1,
                                  prev_log_index = 3,
                                  prev_log_term = 5,
                                  leader_commit = 3},
    % success case - everything is up to date
    {follower, _, {reply, #append_entries_reply{term = 5, success = true}}} =
        raga_node:handle_follower(EmptyAE, State),

    % reply false if term < current_term (5.1)
    {follower, _, {reply, #append_entries_reply{term = 5, success = false}}} =
        raga_node:handle_follower(EmptyAE#append_entries_rpc{term = 4}, State),

    % reply false if log doesn't contain a term matching entry at prev_log_index
    {follower, _, {reply, #append_entries_reply{term = 5, success = false}}} =
        raga_node:handle_follower(EmptyAE#append_entries_rpc{prev_log_index = 4}, State),
    {follower, _, {reply, #append_entries_reply{term = 5, success = false}}} =
        raga_node:handle_follower(EmptyAE#append_entries_rpc{prev_log_term = 4}, State),

    % truncate/overwrite if a existing entry conflicts (diff term) with a new one (5.3)
    AE = #append_entries_rpc{term = 5,
                             leader_id = n1,
                             prev_log_index = 1,
                             prev_log_term = 1,
                             leader_commit = 2,
                             entries = [{2, 4, <<"hi">>}]},

    ExpectedLog = {2, #{1 => {1, <<"hi1">>}, 2 => {4, <<"hi">>}}},
    {follower,  #{log := ExpectedLog},
     {reply, #append_entries_reply{term = 5, success = true}}} =
        raga_node:handle_follower(AE, State#{last_applied => 1}),

    % append new entries not in the log

    % if leader_commit > commit_index set commit_index = min(leader_index, index of last new entry)

    ok.



follower_vote(_Config) ->
    State = base_state(3),
    Msg = #request_vote_rpc{candidate_id = n2, term = 6, last_log_index = 3,
                            last_log_term = 5},
    % success
    {follower, #{voted_for := n2, current_term := 6} = State1,
     {reply, #request_vote_result{term = 6, vote_granted = true}}} =
     raga_node:handle_follower(Msg, State),

    % we can vote again for the same candidate and term
    {follower, #{voted_for := n2, current_term := 6},
     {reply, #request_vote_result{term = 6, vote_granted = true}}} =
     raga_node:handle_follower(Msg, State1),

    % but not for a different candidate
    {follower, #{voted_for := n2, current_term := 6},
     {reply, #request_vote_result{term = 6, vote_granted = false}}} =
     raga_node:handle_follower(Msg#request_vote_rpc{candidate_id = n3}, State1),

   % fail due to lower term
    {follower, #{current_term := 5},
     {reply, #request_vote_result{term = 5, vote_granted = false}}} =
     raga_node:handle_follower(Msg#request_vote_rpc{term = 4}, State),

   % fail due to stale log but still update term if higher
    {follower, #{current_term := 6},
     {reply, #request_vote_result{term = 6, vote_granted = false}}} =
     raga_node:handle_follower(Msg, State#{log => {3, #{}}}),
     ok.


quorum(_Config) ->
    State = (base_state(5))#{current_term => 6, votes => 1},
    Reply = #request_vote_result{term = 6, vote_granted = true},
    {candidate, #{votes := 2} = State1, none}
        = raga_node:handle_candidate(Reply, State),
    % denied
    NegResult = #request_vote_result{term = 6, vote_granted = false},
    {candidate, #{votes := 2}, none}
        = raga_node:handle_candidate(NegResult, State1),
    % newer term should make candidate stand down
    HighTermResult = #request_vote_result{term = 7, vote_granted = false},
    {follower, #{current_term := 7}, none}
        = raga_node:handle_candidate(HighTermResult, State1),

    % quorum has been achieved - candidate becomes leader
    AE = #append_entries_rpc{term = 6,
                             leader_id = n1,
                             prev_log_index = 3,
                             prev_log_term = 5,
                             entries = [],
                             leader_commit = 3
                             },
    PeerState = #{next_index => 3+1, % leaders last log index + 1
                  match_index => 0}, % initd to 0

    Cluster = {normal, #{n1 => #{},
                         n2 => PeerState,
                         n3 => PeerState,
                         n4 => PeerState,
                         n5 => PeerState}},
    {leader, #{cluster := Cluster},
     {append, [{n2, AE} | _ ]}}
               = raga_node:handle_candidate(Reply, State1).

election_timeout(_Config) ->
    State = base_state(3),
    Msg = election_timeout,
    VoteRpc = #request_vote_rpc{term = 6, candidate_id = n1, last_log_index = 3,
                                last_log_term = 5},
    {candidate, #{current_term := 6, votes := 1},
     {vote, [{n2, VoteRpc}, {n3, VoteRpc}]}} = raga_node:handle_follower(Msg, State),
    {candidate, #{current_term := 6, votes := 1},
     {vote, [{n2, VoteRpc}, {n3, VoteRpc}]}} = raga_node:handle_candidate(Msg, State),
    ok.

base_state(NumNodes) ->
    Log = {3, #{1 => {1, <<"hi1">>},
                2 => {3, <<"hi2">>},
                3 => {5, <<"hi3">>}}},
    Nodes = lists:foldl(fun(N, Acc) ->
                                Name = list_to_atom("n" ++ integer_to_list(N)),
                                Acc#{Name => #{}}
                        end, #{}, lists:seq(1, NumNodes)),
    #{id => n1,
      cluster => {normal, Nodes},
      current_term => 5,
      commit_index => 3,
      last_applied => 3,
      machine_apply_fun => fun (_, S) -> S end,
      machine_state => ok,
      log_mod => raga_test_log,
      log => Log}.
