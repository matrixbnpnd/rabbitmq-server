%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_variable_queue).

-export([init/3, terminate/1, delete_and_terminate/1,
         purge/1, publish/2, publish_delivered/3, fetch/2, ack/2,
         tx_publish/3, tx_ack/3, tx_rollback/2, tx_commit/3,
         requeue/2, len/1, is_empty/1,
         set_ram_duration_target/2, ram_duration/1,
         needs_idle_timeout/1, idle_timeout/1, handle_pre_hibernate/1,
         status/1]).

-export([start/1]).

%%----------------------------------------------------------------------------
%% Definitions:

%% alpha: this is a message where both the message itself, and its
%%        position within the queue are held in RAM
%%
%% beta: this is a message where the message itself is only held on
%%        disk, but its position within the queue is held in RAM.
%%
%% gamma: this is a message where the message itself is only held on
%%        disk, but its position is both in RAM and on disk.
%%
%% delta: this is a collection of messages, represented by a single
%%        term, where the messages and their position are only held on
%%        disk.
%%
%% Note that for persistent messages, the message and its position
%% within the queue are always held on disk, *in addition* to being in
%% one of the above classifications.
%%
%% Also note that within this code, the term gamma never
%% appears. Instead, gammas are defined by betas who have had their
%% queue position recorded on disk.
%%
%% In general, messages move q1 -> q2 -> delta -> q3 -> q4, though
%% many of these steps are frequently skipped. q1 and q4 only hold
%% alphas, q2 and q3 hold both betas and gammas (as queues of queues,
%% using the bpqueue module where the block prefix determines whether
%% they're betas or gammas). When a message arrives, its
%% classification is determined. It is then added to the rightmost
%% appropriate queue.
%%
%% If a new message is determined to be a beta or gamma, q1 is
%% empty. If a new message is determined to be a delta, q1 and q2 are
%% empty (and actually q4 too).
%%
%% When removing messages from a queue, if q4 is empty then q3 is read
%% directly. If q3 becomes empty then the next segment's worth of
%% messages from delta are read into q3, reducing the size of
%% delta. If the queue is non empty, either q4 or q3 contain
%% entries. It is never permitted for delta to hold all the messages
%% in the queue.
%%
%% The duration indicated to us by the memory_monitor is used to
%% calculate, given our current ingress and egress rates, how many
%% messages we should hold in RAM. When we need to push alphas to
%% betas or betas to gammas, we favour writing out messages that are
%% further from the head of the queue. This minimises writes to disk,
%% as the messages closer to the tail of the queue stay in the queue
%% for longer, thus do not need to be replaced as quickly by sending
%% other messages to disk.
%%
%% Whilst messages are pushed to disk and forgotten from RAM as soon
%% as requested by a new setting of the queue RAM duration, the
%% inverse is not true: we only load messages back into RAM as
%% demanded as the queue is read from. Thus only publishes to the
%% queue will take up available spare capacity.
%%
%% If a queue is full of transient messages, then the transition from
%% betas to deltas will be potentially very expensive as millions of
%% entries must be written to disk by the queue_index module. This can
%% badly stall the queue. In order to avoid this, the proportion of
%% gammas / (betas+gammas) must not be lower than (betas+gammas) /
%% (alphas+betas+gammas). As the queue grows or available memory
%% shrinks, the latter ratio increases, requiring the conversion of
%% more gammas to betas in order to maintain the invariant. At the
%% point at which betas and gammas must be converted to deltas, there
%% should be very few betas remaining, thus the transition is fast (no
%% work needs to be done for the gamma -> delta transition).
%%
%% The conversion of betas to gammas is done on all actions that can
%% increase the message count, such as publish and requeue, and when
%% the queue is asked to reduce its memory usage. The conversion is
%% done in batches of exactly ?RAM_INDEX_BATCH_SIZE. This value should
%% not be too small, otherwise the frequent operations on the queues
%% of q2 and q3 will not be effectively amortised (switching the
%% direction of queue access defeats amortisation), nor should it be
%% too big, otherwise converting a batch stalls the queue for too
%% long. Therefore, it must be just right. This approach is preferable
%% to doing work on a new queue-duration because converting all the
%% indicated betas to gammas at that point can be far too expensive,
%% thus requiring batching and segmented work anyway.
%%
%% In the queue we only keep track of messages that are pending
%% delivery. This is fine for queue purging, but can be expensive for
%% queue deletion: for queue deletion we must scan all the way through
%% all remaining segments in the queue index (we start by doing a
%% purge) and delete messages from the msg_store that we find in the
%% queue index.
%%
%% Notes on Clean Shutdown
%% (This documents behaviour in variable_queue, queue_index and
%% msg_store.)
%%
%% In order to try to achieve as fast a start-up as possible, if a
%% clean shutdown occurs, we try to save out state to disk to reduce
%% work on startup. In the msg_store this takes the form of the
%% index_module's state, plus the file_summary ets table, and client
%% refs. In the VQ, this takes the form of the count of persistent
%% messages in the queue and references into the msg_stores. The
%% queue_index adds to these terms the details of its segments and
%% stores the terms in the queue directory.
%%
%% The references to the msg_stores are there so that the msg_store
%% knows to only trust its saved state if all of the queues it was
%% previously talking to come up cleanly. Likewise, the queues
%% themselves (esp queue_index) skips work in init if all the queues
%% and msg_store were shutdown cleanly. This gives both good speed
%% improvements and also robustness so that if anything possibly went
%% wrong in shutdown (or there was subsequent manual tampering), all
%% messages and queues that can be recovered are recovered, safely.
%%
%% To delete transient messages lazily, the variable_queue, on
%% startup, stores the next_seq_id reported by the queue_index as the
%% transient_threshold. From that point on, whenever it's reading a
%% message off disk via the queue_index, if the seq_id is below this
%% threshold and the message is transient then it drops the
%% message. This avoids the expensive operation of scanning the entire
%% queue on startup in order to delete transient messages that were
%% only pushed to disk to save memory.
%%
%%----------------------------------------------------------------------------

-behaviour(rabbit_backing_queue).

-record(vqstate,
        { q1,
          q2,
          delta,
          q3,
          q4,
          next_seq_id,
          pending_ack,
          index_state,
          msg_store_clients,
          on_sync,
          durable,
          transient_threshold,

          len,
          persistent_count,

          duration_target,
          target_ram_msg_count,
          ram_msg_count,
          ram_msg_count_prev,
          ram_index_count,
          out_counter,
          in_counter,
          egress_rate,
          avg_egress_rate,
          ingress_rate,
          avg_ingress_rate,
          rate_timestamp
         }).

-record(msg_status,
        { seq_id,
          guid,
          msg,
          is_persistent,
          is_delivered,
          msg_on_disk,
          index_on_disk
         }).

-record(delta,
        { start_seq_id, %% start_seq_id is inclusive
          count,
          end_seq_id    %% end_seq_id is exclusive
         }).

-record(tx, { pending_messages, pending_acks }).

%% When we discover, on publish, that we should write some indices to
%% disk for some betas, the RAM_INDEX_BATCH_SIZE sets the number of
%% betas that we must be due to write indices for before we do any
%% work at all. This is both a minimum and a maximum - we don't write
%% fewer than RAM_INDEX_BATCH_SIZE indices out in one go, and we don't
%% write more - we can always come back on the next publish to do
%% more.
-define(IO_BATCH_SIZE, 64).
-define(PERSISTENT_MSG_STORE, msg_store_persistent).
-define(TRANSIENT_MSG_STORE,  msg_store_transient).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(bpqueue() :: any()).
-type(seq_id()  :: non_neg_integer()).
-type(ack()     :: seq_id() | 'blank_ack').

-type(delta() :: #delta { start_seq_id :: non_neg_integer(),
                          count        :: non_neg_integer (),
                          end_seq_id   :: non_neg_integer() }).

-type(state() :: #vqstate {
             q1                   :: queue(),
             q2                   :: bpqueue(),
             delta                :: delta(),
             q3                   :: bpqueue(),
             q4                   :: queue(),
             next_seq_id          :: seq_id(),
             pending_ack          :: dict(),
             index_state          :: any(),
             msg_store_clients    :: 'undefined' | {{any(), binary()},
                                                    {any(), binary()}},
             on_sync              :: {[[ack()]], [[guid()]],
                                      [fun (() -> any())]},
             durable              :: boolean(),

             len                  :: non_neg_integer(),
             persistent_count     :: non_neg_integer(),

             transient_threshold  :: non_neg_integer(),
             duration_target      :: number() | 'infinity',
             target_ram_msg_count :: non_neg_integer() | 'infinity',
             ram_msg_count        :: non_neg_integer(),
             ram_msg_count_prev   :: non_neg_integer(),
             ram_index_count      :: non_neg_integer(),
             out_counter          :: non_neg_integer(),
             in_counter           :: non_neg_integer(),
             egress_rate          :: {{integer(), integer(), integer()},
                                      non_neg_integer()},
             avg_egress_rate      :: float(),
             ingress_rate         :: {{integer(), integer(), integer()},
                                      non_neg_integer()},
             avg_ingress_rate     :: float(),
             rate_timestamp       :: {integer(), integer(), integer()}
            }).

-include("rabbit_backing_queue_spec.hrl").

-endif.

-define(BLANK_DELTA, #delta { start_seq_id = undefined,
                              count        = 0,
                              end_seq_id   = undefined }).
-define(BLANK_DELTA_PATTERN(Z), #delta { start_seq_id = Z,
                                         count        = 0,
                                         end_seq_id   = Z }).

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

start(DurableQueues) ->
    ok = rabbit_msg_store:clean(?TRANSIENT_MSG_STORE, rabbit_mnesia:dir()),
    {AllTerms, StartFunState} = rabbit_queue_index:recover(DurableQueues),
    Refs = [Ref || Terms <- AllTerms,
                   begin
                       Ref = proplists:get_value(persistent_ref, Terms),
                       Ref =/= undefined
                   end],
    ok = rabbit_sup:start_child(?TRANSIENT_MSG_STORE, rabbit_msg_store,
                                [?TRANSIENT_MSG_STORE, rabbit_mnesia:dir(),
                                 undefined,  {fun (ok) -> finished end, ok}]),
    ok = rabbit_sup:start_child(?PERSISTENT_MSG_STORE, rabbit_msg_store,
                                [?PERSISTENT_MSG_STORE, rabbit_mnesia:dir(),
                                 Refs, StartFunState]).

init(QueueName, IsDurable, _Recover) ->
    MsgStoreRecovered =
        rabbit_msg_store:successfully_recovered_state(?PERSISTENT_MSG_STORE),
    ContainsCheckFun =
        fun (Guid) ->
                rabbit_msg_store:contains(?PERSISTENT_MSG_STORE, Guid)
        end,
    {DeltaCount, Terms, IndexState} =
        rabbit_queue_index:init(QueueName, MsgStoreRecovered, ContainsCheckFun),
    {LowSeqId, NextSeqId, IndexState1} = rabbit_queue_index:bounds(IndexState),

    {PRef, TRef, Terms1} =
        case [persistent_ref, transient_ref] -- proplists:get_keys(Terms) of
            [] -> {proplists:get_value(persistent_ref, Terms),
                   proplists:get_value(transient_ref, Terms),
                   Terms};
            _  -> {rabbit_guid:guid(), rabbit_guid:guid(), []}
        end,
    DeltaCount1 = proplists:get_value(persistent_count, Terms1, DeltaCount),
    Delta = case DeltaCount1 == 0 andalso DeltaCount /= undefined of
                true  -> ?BLANK_DELTA;
                false -> #delta { start_seq_id = LowSeqId,
                                  count        = DeltaCount1,
                                  end_seq_id   = NextSeqId }
            end,
    Now = now(),
    PersistentClient =
        case IsDurable of
            true  -> rabbit_msg_store:client_init(?PERSISTENT_MSG_STORE, PRef);
            false -> undefined
        end,
    TransientClient  = rabbit_msg_store:client_init(?TRANSIENT_MSG_STORE, TRef),
    State = #vqstate {
      q1                   = queue:new(),
      q2                   = bpqueue:new(),
      delta                = Delta,
      q3                   = bpqueue:new(),
      q4                   = queue:new(),
      next_seq_id          = NextSeqId,
      pending_ack          = dict:new(),
      index_state          = IndexState1,
      msg_store_clients    = {{PersistentClient, PRef},
                              {TransientClient, TRef}},
      on_sync              = {[], [], []},
      durable              = IsDurable,
      transient_threshold  = NextSeqId,

      len                  = DeltaCount1,
      persistent_count     = DeltaCount1,

      duration_target      = infinity,
      target_ram_msg_count = infinity,
      ram_msg_count        = 0,
      ram_msg_count_prev   = 0,
      ram_index_count      = 0,
      out_counter          = 0,
      in_counter           = 0,
      egress_rate          = {Now, 0},
      avg_egress_rate      = 0,
      ingress_rate         = {Now, DeltaCount1},
      avg_ingress_rate     = 0,
      rate_timestamp       = Now
     },
    a(maybe_deltas_to_betas(State)).

terminate(State) ->
    State1 = #vqstate { persistent_count  = PCount,
                        index_state       = IndexState,
                        msg_store_clients = {{MSCStateP, PRef},
                                             {MSCStateT, TRef}} } =
        remove_pending_ack(true, tx_commit_index(State)),
    case MSCStateP of
        undefined -> ok;
        _         -> rabbit_msg_store:client_terminate(MSCStateP)
    end,
    rabbit_msg_store:client_terminate(MSCStateT),
    Terms = [{persistent_ref, PRef},
             {transient_ref, TRef},
             {persistent_count, PCount}],
    a(State1 #vqstate { index_state       = rabbit_queue_index:terminate(
                                              Terms, IndexState),
                        msg_store_clients = undefined }).

%% the only difference between purge and delete is that delete also
%% needs to delete everything that's been delivered and not ack'd.
delete_and_terminate(State) ->
    %% TODO: there is no need to interact with qi at all - which we do
    %% as part of 'purge' and 'remove_pending_ack', other than
    %% deleting it.
    {_PurgeCount, State1} = purge(State),
    State2 = #vqstate { index_state         = IndexState,
                        msg_store_clients   = {{MSCStateP, PRef},
                                               {MSCStateT, TRef}} } =
        remove_pending_ack(false, State1),
    IndexState1 = rabbit_queue_index:delete_and_terminate(IndexState),
    case MSCStateP of
        undefined -> ok;
        _         -> rabbit_msg_store:delete_client(
                       ?PERSISTENT_MSG_STORE, PRef),
                     rabbit_msg_store:client_terminate(MSCStateP)
    end,
    rabbit_msg_store:delete_client(?TRANSIENT_MSG_STORE, TRef),
    rabbit_msg_store:client_terminate(MSCStateT),
    a(State2 #vqstate { index_state       = IndexState1,
                        msg_store_clients = undefined }).

purge(State = #vqstate { q4 = Q4, index_state = IndexState, len = Len }) ->
    %% TODO: when there are no pending acks, which is a common case,
    %% we could simply wipe the qi instead of issuing delivers and
    %% acks for all the messages.
    IndexState1 = remove_queue_entries(fun rabbit_misc:queue_fold/3, Q4,
                                       IndexState),
    State1 = #vqstate { q1 = Q1, index_state = IndexState2 } =
        purge_betas_and_deltas(State #vqstate { q4          = queue:new(),
                                                index_state = IndexState1 }),
    IndexState3 = remove_queue_entries(fun rabbit_misc:queue_fold/3, Q1,
                                       IndexState2),
    {Len, a(State1 #vqstate { q1               = queue:new(),
                              index_state      = IndexState3,
                              len              = 0,
                              ram_msg_count    = 0,
                              ram_index_count  = 0,
                              persistent_count = 0 })}.

publish(Msg, State) ->
    {_SeqId, State1} = publish(Msg, false, false, State),
    a(reduce_memory_use(State1)).

publish_delivered(false, _Msg, State = #vqstate { len = 0 }) ->
    {blank_ack, a(State)};
publish_delivered(true, Msg = #basic_message { is_persistent = IsPersistent },
                  State = #vqstate { len               = 0,
                                     next_seq_id       = SeqId,
                                     out_counter       = OutCount,
                                     in_counter        = InCount,
                                     persistent_count  = PCount,
                                     pending_ack       = PA,
                                     durable           = IsDurable }) ->
    IsPersistent1 = IsDurable andalso IsPersistent,
    MsgStatus = (msg_status(IsPersistent1, SeqId, Msg))
        #msg_status { is_delivered = true },
    {MsgStatus1, State1} = maybe_write_to_disk(false, false, MsgStatus, State),
    PA1 = record_pending_ack(MsgStatus1, PA),
    PCount1 = PCount + one_if(IsPersistent1),
    {SeqId, a(State1 #vqstate { next_seq_id       = SeqId    + 1,
                                out_counter       = OutCount + 1,
                                in_counter        = InCount  + 1,
                                persistent_count  = PCount1,
                                pending_ack       = PA1 })}.

fetch(AckRequired, State = #vqstate { q4               = Q4,
                                      ram_msg_count    = RamMsgCount,
                                      out_counter      = OutCount,
                                      index_state      = IndexState,
                                      len              = Len,
                                      persistent_count = PCount,
                                      pending_ack      = PA }) ->
    case queue:out(Q4) of
        {empty, _Q4} ->
            case fetch_from_q3_to_q4(State) of
                {empty, State1} = Result -> a(State1), Result;
                {loaded, State1}         -> fetch(AckRequired, State1)
            end;
        {{value, MsgStatus = #msg_status {
                   msg = Msg, guid = Guid, seq_id = SeqId,
                   is_persistent = IsPersistent, is_delivered = IsDelivered,
                   msg_on_disk = MsgOnDisk, index_on_disk = IndexOnDisk }},
         Q4a} ->

            %% 1. Mark it delivered if necessary
            IndexState1 = maybe_write_delivered(
                            IndexOnDisk andalso not IsDelivered,
                            SeqId, IndexState),

            %% 2. Remove from msg_store and queue index, if necessary
            MsgStore = find_msg_store(IsPersistent),
            Rem = fun () -> ok = rabbit_msg_store:remove(MsgStore, [Guid]) end,
            Ack = fun () -> rabbit_queue_index:ack([SeqId], IndexState1) end,
            IndexState2 =
                case {MsgOnDisk, IndexOnDisk, AckRequired, IsPersistent} of
                    {true, false, false,     _} -> Rem(), IndexState1;
                    {true,  true, false,     _} -> Rem(), Ack();
                    {true,  true,  true, false} -> Ack();
                    _                           -> IndexState1
                end,

            %% 3. If an ack is required, add something sensible to PA
            {AckTag, PA1} = case AckRequired of
                                true  -> PA2 = record_pending_ack(
                                                 MsgStatus #msg_status {
                                                   is_delivered = true }, PA),
                                         {SeqId, PA2};
                                false -> {blank_ack, PA}
                            end,

            PCount1 = PCount - one_if(IsPersistent andalso not AckRequired),
            Len1 = Len - 1,
            {{Msg, IsDelivered, AckTag, Len1},
             a(State #vqstate { q4               = Q4a,
                                ram_msg_count    = RamMsgCount - 1,
                                out_counter      = OutCount + 1,
                                index_state      = IndexState2,
                                len              = Len1,
                                persistent_count = PCount1,
                                pending_ack      = PA1 })}
    end.

ack(AckTags, State) ->
    a(ack(fun rabbit_msg_store:remove/2,
          fun (_AckEntry, State1) -> State1 end,
          AckTags, State)).

tx_publish(Txn, Msg = #basic_message { is_persistent = IsPersistent },
           State = #vqstate { durable           = IsDurable,
                              msg_store_clients = MSCState }) ->
    Tx = #tx { pending_messages = Pubs } = lookup_tx(Txn),
    store_tx(Txn, Tx #tx { pending_messages = [Msg | Pubs] }),
    a(case IsPersistent andalso IsDurable of
          true  -> MsgStatus = msg_status(true, undefined, Msg),
                   {#msg_status { msg_on_disk = true }, MSCState1} =
                       maybe_write_msg_to_disk(false, MsgStatus, MSCState),
                   State #vqstate { msg_store_clients = MSCState1 };
          false -> State
      end).

tx_ack(Txn, AckTags, State) ->
    Tx = #tx { pending_acks = Acks } = lookup_tx(Txn),
    store_tx(Txn, Tx #tx { pending_acks = [AckTags | Acks] }),
    State.

tx_rollback(Txn, State = #vqstate { durable = IsDurable }) ->
    #tx { pending_acks = AckTags, pending_messages = Pubs } = lookup_tx(Txn),
    erase_tx(Txn),
    ok = case IsDurable of
             true  -> rabbit_msg_store:remove(?PERSISTENT_MSG_STORE,
                                              persistent_guids(Pubs));
             false -> ok
         end,
    {lists:flatten(AckTags), a(State)}.

tx_commit(Txn, Fun, State = #vqstate { durable = IsDurable }) ->
    %% If we are a non-durable queue, or we have no persistent pubs,
    %% we can skip the msg_store loop.
    #tx { pending_acks = AckTags, pending_messages = Pubs } = lookup_tx(Txn),
    erase_tx(Txn),
    PubsOrdered = lists:reverse(Pubs),
    AckTags1 = lists:flatten(AckTags),
    PersistentGuids = persistent_guids(PubsOrdered),
    IsTransientPubs = [] == PersistentGuids,
    {AckTags1,
     a(case (not IsDurable) orelse IsTransientPubs of
           true  -> tx_commit_post_msg_store(
                      IsTransientPubs, PubsOrdered, AckTags1, Fun, State);
           false -> ok = rabbit_msg_store:sync(
                           ?PERSISTENT_MSG_STORE, PersistentGuids,
                           msg_store_callback(PersistentGuids, IsTransientPubs,
                                              PubsOrdered, AckTags1, Fun)),
                    State
       end)}.

requeue(AckTags, State) ->
    a(reduce_memory_use(
        ack(fun rabbit_msg_store:release/2,
            fun (#msg_status { msg = Msg }, State1) ->
                    {_SeqId, State2} = publish(Msg, true, false, State1),
                    State2;
                ({IsPersistent, Guid}, State1) ->
                    #vqstate { msg_store_clients = MSCState } = State1,
                    {{ok, Msg = #basic_message{}}, MSCState1} =
                        read_from_msg_store(MSCState, IsPersistent, Guid),
                    State2 = State1 #vqstate { msg_store_clients = MSCState1 },
                    {_SeqId, State3} = publish(Msg, true, true, State2),
                    State3
            end,
            AckTags, State))).

len(#vqstate { len = Len }) -> Len.

is_empty(State) -> 0 == len(State).

set_ram_duration_target(DurationTarget,
                        State = #vqstate {
                          avg_egress_rate      = AvgEgressRate,
                          avg_ingress_rate     = AvgIngressRate,
                          target_ram_msg_count = TargetRamMsgCount }) ->
    Rate = AvgEgressRate + AvgIngressRate,
    TargetRamMsgCount1 =
        case DurationTarget of
            infinity  -> infinity;
            _         -> trunc(DurationTarget * Rate) %% msgs = sec * msgs/sec
        end,
    State1 = State #vqstate { target_ram_msg_count = TargetRamMsgCount1,
                              duration_target      = DurationTarget },
    a(case TargetRamMsgCount1 == infinity orelse
          TargetRamMsgCount1 >= TargetRamMsgCount of
          true  -> State1;
          false -> reduce_memory_use(State1)
      end).

ram_duration(State = #vqstate { egress_rate        = Egress,
                                ingress_rate       = Ingress,
                                rate_timestamp     = Timestamp,
                                in_counter         = InCount,
                                out_counter        = OutCount,
                                ram_msg_count      = RamMsgCount,
                                duration_target    = DurationTarget,
                                ram_msg_count_prev = RamMsgCountPrev }) ->
    Now = now(),
    {AvgEgressRate,   Egress1} = update_rate(Now, Timestamp, OutCount, Egress),
    {AvgIngressRate, Ingress1} = update_rate(Now, Timestamp, InCount, Ingress),

    Duration = %% msgs / (msgs/sec) == sec
        case AvgEgressRate == 0 andalso AvgIngressRate == 0 of
            true  -> infinity;
            false -> (RamMsgCountPrev + RamMsgCount) /
                         (2 * (AvgEgressRate + AvgIngressRate))
        end,

    {Duration, set_ram_duration_target(DurationTarget,
                                       State #vqstate {
                                         egress_rate        = Egress1,
                                         avg_egress_rate    = AvgEgressRate,
                                         ingress_rate       = Ingress1,
                                         avg_ingress_rate   = AvgIngressRate,
                                         rate_timestamp     = Now,
                                         in_counter         = 0,
                                         out_counter        = 0,
                                         ram_msg_count_prev = RamMsgCount })}.

needs_idle_timeout(#vqstate { on_sync = {_, _, [_|_]}}) ->
    true;
needs_idle_timeout(State) ->
    {Res, _State} = reduce_memory_use(fun (_Quota, State1) -> State1 end,
                                      fun (_Quota, State1) -> State1 end,
                                      fun (State1)         -> State1 end,
                                      State),
    Res.

idle_timeout(State) -> a(reduce_memory_use(tx_commit_index(State))).

handle_pre_hibernate(State = #vqstate { index_state = IndexState }) ->
    State #vqstate { index_state = rabbit_queue_index:flush(IndexState) }.

status(#vqstate { q1 = Q1, q2 = Q2, delta = Delta, q3 = Q3, q4 = Q4,
                  len                  = Len,
                  on_sync              = {_, _, From},
                  target_ram_msg_count = TargetRamMsgCount,
                  ram_msg_count        = RamMsgCount,
                  ram_index_count      = RamIndexCount,
                  avg_egress_rate      = AvgEgressRate,
                  avg_ingress_rate     = AvgIngressRate,
                  next_seq_id          = NextSeqId }) ->
    [ {q1                   , queue:len(Q1)},
      {q2                   , bpqueue:len(Q2)},
      {delta                , Delta},
      {q3                   , bpqueue:len(Q3)},
      {q4                   , queue:len(Q4)},
      {len                  , Len},
      {outstanding_txns     , length(From)},
      {target_ram_msg_count , TargetRamMsgCount},
      {ram_msg_count        , RamMsgCount},
      {ram_index_count      , RamIndexCount},
      {avg_egress_rate      , AvgEgressRate},
      {avg_ingress_rate     , AvgIngressRate},
      {next_seq_id          , NextSeqId} ].

%%----------------------------------------------------------------------------
%% Minor helpers
%%----------------------------------------------------------------------------

a(State = #vqstate { q1 = Q1, q2 = Q2, delta = Delta, q3 = Q3, q4 = Q4,
                     len                  = Len,
                     persistent_count     = PersistentCount,
                     ram_msg_count        = RamMsgCount,
                     ram_index_count      = RamIndexCount }) ->
    E1 = queue:is_empty(Q1),
    E2 = bpqueue:is_empty(Q2),
    ED = Delta#delta.count == 0,
    E3 = bpqueue:is_empty(Q3),
    E4 = queue:is_empty(Q4),
    LZ = Len == 0,

    true = E1 or not E3,
    true = E2 or not ED,
    true = ED or not E3,
    true = LZ == (E3 and E4),

    true = Len             >= 0,
    true = PersistentCount >= 0,
    true = RamMsgCount     >= 0,
    true = RamIndexCount   >= 0,

    State.

one_if(true ) -> 1;
one_if(false) -> 0.

msg_status(IsPersistent, SeqId, Msg = #basic_message { guid = Guid }) ->
    #msg_status { seq_id = SeqId, guid = Guid, msg = Msg,
                  is_persistent = IsPersistent, is_delivered = false,
                  msg_on_disk = false, index_on_disk = false }.

find_msg_store(true)  -> ?PERSISTENT_MSG_STORE;
find_msg_store(false) -> ?TRANSIENT_MSG_STORE.

with_msg_store_state({{MSCStateP, PRef}, MSCStateT}, true, Fun) ->
    {Result, MSCStateP1} = Fun(?PERSISTENT_MSG_STORE, MSCStateP),
    {Result, {{MSCStateP1, PRef}, MSCStateT}};
with_msg_store_state({MSCStateP, {MSCStateT, TRef}}, false, Fun) ->
    {Result, MSCStateT1} = Fun(?TRANSIENT_MSG_STORE, MSCStateT),
    {Result, {MSCStateP, {MSCStateT1, TRef}}}.

read_from_msg_store(MSCState, IsPersistent, Guid) ->
    with_msg_store_state(
      MSCState, IsPersistent,
      fun (MsgStore, MSCState1) ->
              rabbit_msg_store:read(MsgStore, Guid, MSCState1)
      end).

maybe_write_delivered(false, _SeqId, IndexState) ->
    IndexState;
maybe_write_delivered(true, SeqId, IndexState) ->
    rabbit_queue_index:deliver([SeqId], IndexState).

accumulate_ack(SeqId, IsPersistent, Guid, {SeqIdsAcc, Dict}) ->
    {case IsPersistent of
         true  -> [SeqId | SeqIdsAcc];
         false -> SeqIdsAcc
     end, rabbit_misc:dict_cons(find_msg_store(IsPersistent), Guid, Dict)}.

record_pending_ack(#msg_status { guid = Guid, seq_id = SeqId,
                                 is_persistent = IsPersistent,
                                 msg_on_disk = MsgOnDisk } = MsgStatus, PA) ->
    AckEntry = case MsgOnDisk of
                   true  -> {IsPersistent, Guid};
                   false -> MsgStatus
               end,
    dict:store(SeqId, AckEntry, PA).

remove_pending_ack(KeepPersistent,
                   State = #vqstate { pending_ack = PA,
                                      index_state = IndexState }) ->
    {{SeqIds, GuidsByStore}, PA1} =
        dict:fold(
          fun (SeqId, {IsPersistent, Guid}, {Acc, PA2}) ->
                  {accumulate_ack(SeqId, IsPersistent, Guid, Acc),
                   case KeepPersistent andalso IsPersistent of
                       true  -> PA2;
                       false -> dict:erase(SeqId, PA2)
                   end};
              (SeqId, #msg_status {}, {Acc, PA2}) ->
                  {Acc, dict:erase(SeqId, PA2)}
          end, {{[], dict:new()}, PA}, PA),
    case KeepPersistent of
        true  -> State1 = State #vqstate { pending_ack = PA1 },
                 case dict:find(?TRANSIENT_MSG_STORE, GuidsByStore) of
                     error       -> State1;
                     {ok, Guids} -> ok = rabbit_msg_store:remove(
                                           ?TRANSIENT_MSG_STORE, Guids),
                                    State1
                 end;
        false -> IndexState1 = rabbit_queue_index:ack(SeqIds, IndexState),
                 ok = dict:fold(fun (MsgStore, Guids, ok) ->
                                        rabbit_msg_store:remove(MsgStore, Guids)
                                end, ok, GuidsByStore),
                 State #vqstate { pending_ack = dict:new(),
                                  index_state = IndexState1 }
    end.

lookup_tx(Txn) -> case get({txn, Txn}) of
                      undefined -> #tx { pending_messages = [],
                                         pending_acks     = [] };
                      V         -> V
                  end.

store_tx(Txn, Tx) -> put({txn, Txn}, Tx).

erase_tx(Txn) -> erase({txn, Txn}).

update_rate(Now, Then, Count, {OThen, OCount}) ->
    %% form the avg over the current period and the previous
    Avg = 1000000 * ((Count + OCount) / timer:now_diff(Now, OThen)),
    {Avg, {Then, Count}}.

persistent_guids(Pubs) ->
    [Guid || #basic_message { guid = Guid, is_persistent = true } <- Pubs].

betas_from_index_entries(List, TransientThreshold, IndexState) ->
    {Filtered, Delivers, Acks} =
        lists:foldr(
          fun ({Guid, SeqId, IsPersistent, IsDelivered},
               {Filtered1, Delivers1, Acks1}) ->
                  case SeqId < TransientThreshold andalso not IsPersistent of
                      true  -> {Filtered1,
                                case IsDelivered of
                                    true  -> Delivers1;
                                    false -> [SeqId | Delivers1]
                                end,
                                [SeqId | Acks1]};
                      false -> {[#msg_status { msg           = undefined,
                                               guid          = Guid,
                                               seq_id        = SeqId,
                                               is_persistent = IsPersistent,
                                               is_delivered  = IsDelivered,
                                               msg_on_disk   = true,
                                               index_on_disk = true
                                             } | Filtered1],
                                Delivers1,
                                Acks1}
                  end
          end, {[], [], []}, List),
    {bpqueue:from_list([{true, Filtered}]),
     rabbit_queue_index:ack(Acks,
                            rabbit_queue_index:deliver(Delivers, IndexState))}.

ensure_binary_properties(Msg = #basic_message { content = Content }) ->
    Msg #basic_message {
      content = rabbit_binary_parser:clear_decoded_content(
                  rabbit_binary_generator:ensure_content_encoded(Content)) }.

%% the first arg is the older delta
combine_deltas(?BLANK_DELTA_PATTERN(X), ?BLANK_DELTA_PATTERN(Y)) ->
    ?BLANK_DELTA;
combine_deltas(?BLANK_DELTA_PATTERN(X), #delta { start_seq_id = Start,
                                                 count        = Count,
                                                 end_seq_id   = End } = B) ->
    true = Start + Count =< End, %% ASSERTION
    B;
combine_deltas(#delta { start_seq_id = Start,
                        count        = Count,
                        end_seq_id   = End } = A, ?BLANK_DELTA_PATTERN(Y)) ->
    true = Start + Count =< End, %% ASSERTION
    A;
combine_deltas(#delta { start_seq_id = StartLow,
                        count        = CountLow,
                        end_seq_id   = EndLow },
               #delta { start_seq_id = StartHigh,
                        count        = CountHigh,
                        end_seq_id   = EndHigh }) ->
    Count = CountLow + CountHigh,
    true = (StartLow =< StartHigh) %% ASSERTIONS
        andalso ((StartLow + CountLow) =< EndLow)
        andalso ((StartHigh + CountHigh) =< EndHigh)
        andalso ((StartLow + Count) =< EndHigh),
    #delta { start_seq_id = StartLow, count = Count, end_seq_id = EndHigh }.

beta_fold(Fun, Init, Q) ->
    bpqueue:foldr(fun (_Prefix, Value, Acc) -> Fun(Value, Acc) end, Init, Q).

%%----------------------------------------------------------------------------
%% Internal major helpers for Public API
%%----------------------------------------------------------------------------

ack(_MsgStoreFun, _Fun, [], State) ->
    State;
ack(MsgStoreFun, Fun, AckTags, State) ->
    {{SeqIds, GuidsByStore}, State1 = #vqstate { index_state      = IndexState,
                                                 persistent_count = PCount }} =
        lists:foldl(
          fun (SeqId, {Acc, State2 = #vqstate { pending_ack = PA }}) ->
                  {ok, AckEntry} = dict:find(SeqId, PA),
                  {case AckEntry of
                       #msg_status { index_on_disk = false, %% ASSERTIONS
                                     msg_on_disk   = false,
                                     is_persistent = false } ->
                           Acc;
                       {IsPersistent, Guid} ->
                           accumulate_ack(SeqId, IsPersistent, Guid, Acc)
                   end, Fun(AckEntry, State2 #vqstate {
                                        pending_ack = dict:erase(SeqId, PA) })}
          end, {{[], dict:new()}, State}, AckTags),
    IndexState1 = rabbit_queue_index:ack(SeqIds, IndexState),
    ok = dict:fold(fun (MsgStore, Guids, ok) ->
                           MsgStoreFun(MsgStore, Guids)
                   end, ok, GuidsByStore),
    PCount1 = PCount - case dict:find(?PERSISTENT_MSG_STORE, GuidsByStore) of
                           error        -> 0;
                           {ok, Guids} -> length(Guids)
                       end,
    State1 #vqstate { index_state      = IndexState1,
                      persistent_count = PCount1 }.

msg_store_callback(PersistentGuids, IsTransientPubs, Pubs, AckTags, Fun) ->
    Self = self(),
    F = fun () -> rabbit_amqqueue:maybe_run_queue_via_backing_queue(
                    Self, fun (StateN) -> tx_commit_post_msg_store(
                                            IsTransientPubs, Pubs,
                                            AckTags, Fun, StateN)
                          end)
        end,
    fun () -> spawn(fun () -> ok = rabbit_misc:with_exit_handler(
                                     fun () -> rabbit_msg_store:remove(
                                                 ?PERSISTENT_MSG_STORE,
                                                 PersistentGuids)
                                     end, F)
                    end)
    end.

tx_commit_post_msg_store(IsTransientPubs, Pubs, AckTags, Fun,
                         State = #vqstate {
                           on_sync     = OnSync = {SAcks, SPubs, SFuns},
                           pending_ack = PA,
                           durable     = IsDurable }) ->
    %% If we are a non-durable queue, or (no persisent pubs, and no
    %% persistent acks) then we can skip the queue_index loop.
    case (not IsDurable) orelse
        (IsTransientPubs andalso
         lists:foldl(
           fun (AckTag,  true ) ->
                   case dict:find(AckTag, PA) of
                       {ok, #msg_status {}}         -> true;
                       {ok, {IsPersistent, _Guid}} -> not IsPersistent
                   end;
               (_AckTag, false) -> false
           end, true, AckTags)) of
        true  -> State1 = tx_commit_index(State #vqstate {
                                            on_sync = {[], [Pubs], [Fun]} }),
                 State1 #vqstate { on_sync = OnSync };
        false -> State #vqstate { on_sync = { [AckTags | SAcks],
                                              [Pubs | SPubs],
                                              [Fun | SFuns] }}
    end.

tx_commit_index(State = #vqstate { on_sync = {_, _, []} }) ->
    State;
tx_commit_index(State = #vqstate { on_sync = {SAcks, SPubs, SFuns},
                                   durable = IsDurable }) ->
    Acks = lists:flatten(SAcks),
    Pubs = lists:flatten(lists:reverse(SPubs)),
    {SeqIds, State1 = #vqstate { index_state = IndexState }} =
        lists:foldl(
          fun (Msg = #basic_message { is_persistent = IsPersistent },
               {SeqIdsAcc, State2}) ->
                  IsPersistent1 = IsDurable andalso IsPersistent,
                  {SeqId, State3} = publish(Msg, false, IsPersistent1, State2),
                  {case IsPersistent1 of
                       true  -> [SeqId | SeqIdsAcc];
                       false -> SeqIdsAcc
                   end, State3}
          end, {Acks, ack(Acks, State)}, Pubs),
    IndexState1 = rabbit_queue_index:sync(SeqIds, IndexState),
    [ Fun() || Fun <- lists:reverse(SFuns) ],
    reduce_memory_use(
      State1 #vqstate { index_state = IndexState1, on_sync = {[], [], []} }).

purge_betas_and_deltas(State = #vqstate { q3          = Q3,
                                          index_state = IndexState }) ->
    case bpqueue:is_empty(Q3) of
        true  -> State;
        false -> IndexState1 = remove_queue_entries(fun beta_fold/3, Q3,
                                                    IndexState),
                 purge_betas_and_deltas(
                   maybe_deltas_to_betas(
                     State #vqstate { q3          = bpqueue:new(),
                                      index_state = IndexState1 }))
    end.

remove_queue_entries(Fold, Q, IndexState) ->
    {GuidsByStore, Delivers, Acks} =
        Fold(fun remove_queue_entries1/2, {dict:new(), [], []}, Q),
    ok = dict:fold(fun (MsgStore, Guids, ok) ->
                           rabbit_msg_store:remove(MsgStore, Guids)
                   end, ok, GuidsByStore),
    rabbit_queue_index:ack(Acks,
                           rabbit_queue_index:deliver(Delivers, IndexState)).

remove_queue_entries1(
  #msg_status { guid = Guid, seq_id = SeqId,
                is_delivered = IsDelivered, msg_on_disk = MsgOnDisk,
                index_on_disk = IndexOnDisk, is_persistent = IsPersistent },
  {GuidsByStore, Delivers, Acks}) ->
    {case MsgOnDisk of
         true  -> rabbit_misc:dict_cons(find_msg_store(IsPersistent), Guid,
                                        GuidsByStore);
         false -> GuidsByStore
     end,
     case IndexOnDisk andalso not IsDelivered of
         true  -> [SeqId | Delivers];
         false -> Delivers
     end,
     case IndexOnDisk of
         true  -> [SeqId | Acks];
         false -> Acks
     end}.

fetch_from_q3_to_q4(State = #vqstate {
                      q1                = Q1,
                      q2                = Q2,
                      delta             = #delta { count = DeltaCount },
                      q3                = Q3,
                      q4                = Q4,
                      ram_msg_count     = RamMsgCount,
                      ram_index_count   = RamIndexCount,
                      msg_store_clients = MSCState }) ->
    case bpqueue:out(Q3) of
        {empty, _Q3} ->
            {empty, State};
        {{value, IndexOnDisk, MsgStatus = #msg_status {
                                msg = undefined, guid = Guid,
                                is_persistent = IsPersistent }}, Q3a} ->
            {{ok, Msg = #basic_message {}}, MSCState1} =
                read_from_msg_store(MSCState, IsPersistent, Guid),
            Q4a = queue:in(MsgStatus #msg_status { msg = Msg }, Q4),
            RamIndexCount1 = RamIndexCount - one_if(not IndexOnDisk),
            true = RamIndexCount1 >= 0, %% ASSERTION
            State1 = State #vqstate { q3                = Q3a,
                                      q4                = Q4a,
                                      ram_msg_count     = RamMsgCount + 1,
                                      ram_index_count   = RamIndexCount1,
                                      msg_store_clients = MSCState1 },
            State2 =
                case {bpqueue:is_empty(Q3a), 0 == DeltaCount} of
                    {true, true} ->
                        %% q3 is now empty, it wasn't before; delta is
                        %% still empty. So q2 must be empty, and q1
                        %% can now be joined onto q4
                        true = bpqueue:is_empty(Q2), %% ASSERTION
                        State1 #vqstate { q1 = queue:new(),
                                          q4 = queue:join(Q4a, Q1) };
                    {true, false} ->
                        maybe_deltas_to_betas(State1);
                    {false, _} ->
                        %% q3 still isn't empty, we've not touched
                        %% delta, so the invariants between q1, q2,
                        %% delta and q3 are maintained
                        State1
                end,
            {loaded, State2}
    end.

%%----------------------------------------------------------------------------
%% Internal gubbins for publishing
%%----------------------------------------------------------------------------

publish(Msg = #basic_message { is_persistent = IsPersistent },
        IsDelivered, MsgOnDisk,
        State = #vqstate { q1 = Q1, q3 = Q3, q4 = Q4,
                           next_seq_id      = SeqId,
                           len              = Len,
                           in_counter       = InCount,
                           persistent_count = PCount,
                           durable          = IsDurable,
                           ram_msg_count    = RamMsgCount }) ->
    IsPersistent1 = IsDurable andalso IsPersistent,
    MsgStatus = (msg_status(IsPersistent1, SeqId, Msg))
        #msg_status { is_delivered = IsDelivered, msg_on_disk = MsgOnDisk },
    {MsgStatus1, State1} = maybe_write_to_disk(false, false, MsgStatus, State),
    State2 = case bpqueue:is_empty(Q3) of
                 false -> State1 #vqstate { q1 = queue:in(MsgStatus1, Q1) };
                 true  -> State1 #vqstate { q4 = queue:in(MsgStatus1, Q4) }
             end,
    PCount1 = PCount + one_if(IsPersistent1),
    {SeqId, State2 #vqstate { next_seq_id      = SeqId   + 1,
                              len              = Len     + 1,
                              in_counter       = InCount + 1,
                              persistent_count = PCount1,
                              ram_msg_count    = RamMsgCount + 1}}.

maybe_write_msg_to_disk(_Force, MsgStatus = #msg_status {
                                  msg_on_disk = true }, MSCState) ->
    {MsgStatus, MSCState};
maybe_write_msg_to_disk(Force, MsgStatus = #msg_status {
                                 msg = Msg, guid = Guid,
                                 is_persistent = IsPersistent }, MSCState)
  when Force orelse IsPersistent ->
    {ok, MSCState1} =
        with_msg_store_state(
          MSCState, IsPersistent,
          fun (MsgStore, MSCState2) ->
                  rabbit_msg_store:write(
                    MsgStore, Guid, ensure_binary_properties(Msg), MSCState2)
          end),
    {MsgStatus #msg_status { msg_on_disk = true }, MSCState1};
maybe_write_msg_to_disk(_Force, MsgStatus, MSCState) ->
    {MsgStatus, MSCState}.

maybe_write_index_to_disk(_Force, MsgStatus = #msg_status {
                                    index_on_disk = true }, IndexState) ->
    true = MsgStatus #msg_status.msg_on_disk, %% ASSERTION
    {MsgStatus, IndexState};
maybe_write_index_to_disk(Force, MsgStatus = #msg_status {
                                   guid = Guid, seq_id = SeqId,
                                   is_persistent = IsPersistent,
                                   is_delivered = IsDelivered }, IndexState)
  when Force orelse IsPersistent ->
    true = MsgStatus #msg_status.msg_on_disk, %% ASSERTION
    IndexState1 = rabbit_queue_index:publish(Guid, SeqId, IsPersistent,
                                             IndexState),
    {MsgStatus #msg_status { index_on_disk = true },
     maybe_write_delivered(IsDelivered, SeqId, IndexState1)};
maybe_write_index_to_disk(_Force, MsgStatus, IndexState) ->
    {MsgStatus, IndexState}.

maybe_write_to_disk(ForceMsg, ForceIndex, MsgStatus,
                    State = #vqstate { index_state       = IndexState,
                                       msg_store_clients = MSCState }) ->
    {MsgStatus1, MSCState1}   = maybe_write_msg_to_disk(
                                  ForceMsg, MsgStatus, MSCState),
    {MsgStatus2, IndexState1} = maybe_write_index_to_disk(
                                  ForceIndex, MsgStatus1, IndexState),
    {MsgStatus2, State #vqstate { index_state       = IndexState1,
                                  msg_store_clients = MSCState1 }}.

%%----------------------------------------------------------------------------
%% Phase changes
%%----------------------------------------------------------------------------

%% Determine whether a reduction in memory use is necessary, and call
%% functions to perform the required phase changes. The function can
%% also be used to just do the former, by passing in dummy phase
%% change functions.
%%
%% The function does not report on any needed beta->delta conversions,
%% though the conversion function for that is called as necessary. The
%% reason is twofold. Firstly, this is safe because the conversion is
%% only ever necessary just after a transition to a
%% target_ram_msg_count of zero or after an incremental alpha->beta
%% conversion. In the former case the conversion is performed straight
%% away (i.e. any betas present at the time are converted to deltas),
%% and in the latter case the need for a conversion is flagged up
%% anyway. Secondly, this is necessary because we do not have a
%% precise and cheap predicate for determining whether a beta->delta
%% conversion is necessary - due to the complexities of retaining up
%% one segment's worth of messages in q3 - and thus would risk
%% perpetually reporting the need for a conversion when no such
%% conversion is needed. That in turn could cause an infinite loop.
reduce_memory_use(AlphaBetaFun, BetaGammaFun, BetaDeltaFun, State) ->
    {Reduce, State1} = case chunk_size(State #vqstate.ram_msg_count,
                                       State #vqstate.target_ram_msg_count) of
                           0  -> {false, State};
                           S1 -> {true, AlphaBetaFun(S1, State)}
                       end,
    case State1 #vqstate.target_ram_msg_count of
        infinity -> {Reduce, State1};
        0        -> {Reduce, BetaDeltaFun(State1)};
        _        -> case chunk_size(State1 #vqstate.ram_index_count,
                                   permitted_ram_index_count(State1)) of
                        ?IO_BATCH_SIZE = S2 -> {true, BetaGammaFun(S2, State1)};
                        _                   -> {Reduce, State1}
                    end
    end.

reduce_memory_use(State) ->
    {_, State1} = reduce_memory_use(fun push_alphas_to_betas/2,
                                    fun limit_ram_index/2,
                                    fun push_betas_to_deltas/1,
                                    State),
    State1.

limit_ram_index(Quota, State = #vqstate { q2 = Q2, q3 = Q3,
                                          index_state = IndexState,
                                          ram_index_count = RamIndexCount }) ->
    {Q2a, {Quota1, IndexState1}} = limit_ram_index(
                                     fun bpqueue:map_fold_filter_l/4,
                                     Q2, {Quota, IndexState}),
    %% TODO: we shouldn't be writing index entries for messages that
    %% can never end up in delta due them residing in the only segment
    %% held by q3.
    {Q3a, {Quota2, IndexState2}} = limit_ram_index(
                                     fun bpqueue:map_fold_filter_r/4,
                                     Q3, {Quota1, IndexState1}),
    State #vqstate { q2 = Q2a, q3 = Q3a,
                     index_state = IndexState2,
                     ram_index_count = RamIndexCount - (Quota - Quota2) }.

limit_ram_index(_MapFoldFilterFun, Q, {0, IndexState}) ->
    {Q, {0, IndexState}};
limit_ram_index(MapFoldFilterFun, Q, {Quota, IndexState}) ->
    MapFoldFilterFun(
      fun erlang:'not'/1,
      fun (MsgStatus, {0, _IndexStateN}) ->
              false = MsgStatus #msg_status.index_on_disk, %% ASSERTION
              stop;
          (MsgStatus, {N, IndexStateN}) when N > 0 ->
              false = MsgStatus #msg_status.index_on_disk, %% ASSERTION
              {MsgStatus1, IndexStateN1} =
                  maybe_write_index_to_disk(true, MsgStatus, IndexStateN),
              {true, MsgStatus1, {N-1, IndexStateN1}}
      end, {Quota, IndexState}, Q).

permitted_ram_index_count(#vqstate { len = 0 }) ->
    infinity;
permitted_ram_index_count(#vqstate { len   = Len,
                                     q2    = Q2,
                                     q3    = Q3,
                                     delta = #delta { count = DeltaCount } }) ->
    BetaLen = bpqueue:len(Q2) + bpqueue:len(Q3),
    BetaLen - trunc(BetaLen * BetaLen / (Len - DeltaCount)).

chunk_size(Current, Permitted)
  when Permitted =:= infinity orelse Permitted >= Current ->
    0;
chunk_size(Current, Permitted) ->
    lists:min([Current - Permitted, ?IO_BATCH_SIZE]).

maybe_deltas_to_betas(State = #vqstate { delta = ?BLANK_DELTA_PATTERN(X) }) ->
    State;
maybe_deltas_to_betas(State = #vqstate {
                        q2                   = Q2,
                        delta                = Delta,
                        q3                   = Q3,
                        index_state          = IndexState,
                        target_ram_msg_count = TargetRamMsgCount,
                        transient_threshold  = TransientThreshold }) ->
    case bpqueue:is_empty(Q3) orelse (TargetRamMsgCount /= 0) of
        false ->
            State;
        true ->
            #delta { start_seq_id = DeltaSeqId,
                     count        = DeltaCount,
                     end_seq_id   = DeltaSeqIdEnd } = Delta,
            DeltaSeqId1 =
                lists:min([rabbit_queue_index:next_segment_boundary(DeltaSeqId),
                           DeltaSeqIdEnd]),
            {List, IndexState1} =
                rabbit_queue_index:read(DeltaSeqId, DeltaSeqId1, IndexState),
            {Q3a, IndexState2} = betas_from_index_entries(
                                   List, TransientThreshold, IndexState1),
            State1 = State #vqstate { index_state = IndexState2 },
            case bpqueue:len(Q3a) of
                0 ->
                    %% we ignored every message in the segment due to
                    %% it being transient and below the threshold
                    maybe_deltas_to_betas(
                      State #vqstate {
                        delta = Delta #delta { start_seq_id = DeltaSeqId1 }});
                Q3aLen ->
                    Q3b = bpqueue:join(Q3, Q3a),
                    case DeltaCount - Q3aLen of
                        0 ->
                            %% delta is now empty, but it wasn't
                            %% before, so can now join q2 onto q3
                            State1 #vqstate { q2    = bpqueue:new(),
                                              delta = ?BLANK_DELTA,
                                              q3    = bpqueue:join(Q3b, Q2) };
                        N when N > 0 ->
                            Delta1 = #delta { start_seq_id = DeltaSeqId1,
                                              count        = N,
                                              end_seq_id   = DeltaSeqIdEnd },
                            State1 #vqstate { delta = Delta1,
                                              q3    = Q3b }
                    end
            end
    end.

push_alphas_to_betas(Quota, State) ->
    { Quota1, State1} = maybe_push_q1_to_betas(Quota,  State),
    {_Quota2, State2} = maybe_push_q4_to_betas(Quota1, State1),
    State2.

maybe_push_q1_to_betas(0, State) ->
    {0, State};
maybe_push_q1_to_betas(Quota, State = #vqstate { q1 = Q1 }) ->
    maybe_push_alphas_to_betas(
      fun queue:out/1,
      fun (MsgStatus = #msg_status { index_on_disk = IndexOnDisk },
           Q1a, State1 = #vqstate { q3 = Q3, delta = #delta { count = 0 } }) ->
              State1 #vqstate { q1 = Q1a,
                                q3 = bpqueue:in(IndexOnDisk, MsgStatus, Q3) };
          (MsgStatus = #msg_status { index_on_disk = IndexOnDisk },
           Q1a, State1 = #vqstate { q2 = Q2 }) ->
              State1 #vqstate { q1 = Q1a,
                                q2 = bpqueue:in(IndexOnDisk, MsgStatus, Q2) }
      end, Quota, Q1, State).

maybe_push_q4_to_betas(0, State) ->
    {0, State};
maybe_push_q4_to_betas(Quota, State = #vqstate { q4 = Q4 }) ->
    maybe_push_alphas_to_betas(
      fun queue:out_r/1,
      fun (MsgStatus = #msg_status { index_on_disk = IndexOnDisk },
           Q4a, State1 = #vqstate { q3 = Q3 }) ->
              State1 #vqstate { q3 = bpqueue:in_r(IndexOnDisk, MsgStatus, Q3),
                                q4 = Q4a }
      end, Quota, Q4, State).

maybe_push_alphas_to_betas(_Generator, _Consumer, Quota, _Q,
                           State = #vqstate {
                             ram_msg_count        = RamMsgCount,
                             target_ram_msg_count = TargetRamMsgCount })
  when Quota =:= 0 orelse
       TargetRamMsgCount =:= infinity orelse TargetRamMsgCount >= RamMsgCount ->
    {Quota, State};
maybe_push_alphas_to_betas(Generator, Consumer, Quota, Q, State) ->
    case Generator(Q) of
        {empty, _Q} ->
            {Quota, State};
        {{value, MsgStatus}, Qa} ->
            {MsgStatus1 = #msg_status { msg_on_disk = true,
                                        index_on_disk = IndexOnDisk },
             State1 = #vqstate { ram_msg_count   = RamMsgCount,
                                 ram_index_count = RamIndexCount }} =
                maybe_write_to_disk(true, false, MsgStatus, State),
            MsgStatus2 = MsgStatus1 #msg_status { msg = undefined },
            RamIndexCount1 = RamIndexCount + one_if(not IndexOnDisk),
            State2 = State1 #vqstate { ram_msg_count = RamMsgCount - 1,
                                       ram_index_count = RamIndexCount1 },
            maybe_push_alphas_to_betas(Generator, Consumer, Quota - 1, Qa,
                                       Consumer(MsgStatus2, Qa, State2))
    end.

push_betas_to_deltas(State = #vqstate { q2              = Q2,
                                        delta           = Delta,
                                        q3              = Q3,
                                        index_state     = IndexState,
                                        ram_index_count = RamIndexCount }) ->
    {Delta2, Q2a, RamIndexCount2, IndexState2} =
        push_betas_to_deltas(fun (Q2MinSeqId) -> Q2MinSeqId end,
                             fun bpqueue:out/1, Q2,
                             RamIndexCount, IndexState),
    {Delta3, Q3a, RamIndexCount3, IndexState3} =
        push_betas_to_deltas(fun rabbit_queue_index:next_segment_boundary/1,
                             fun bpqueue:out_r/1, Q3,
                             RamIndexCount2, IndexState2),
    Delta4 = combine_deltas(Delta3, combine_deltas(Delta, Delta2)),
    State #vqstate { q2              = Q2a,
                     delta           = Delta4,
                     q3              = Q3a,
                     index_state     = IndexState3,
                     ram_index_count = RamIndexCount3 }.

push_betas_to_deltas(LimitFun, Generator, Q, RamIndexCount, IndexState) ->
    case bpqueue:out(Q) of
        {empty, _Q} ->
            {?BLANK_DELTA, Q, RamIndexCount, IndexState};
        {{value, _IndexOnDisk1, #msg_status { seq_id = MinSeqId }}, _Qa} ->
            {{value, _IndexOnDisk2, #msg_status { seq_id = MaxSeqId }}, _Qb} =
                bpqueue:out_r(Q),
            Limit = LimitFun(MinSeqId),
            case MaxSeqId < Limit of
                true  -> {?BLANK_DELTA, Q, RamIndexCount, IndexState};
                false -> {Len, Qc, RamIndexCount1, IndexState1} =
                             push_betas_to_deltas(Generator, Limit, Q, 0,
                                                  RamIndexCount, IndexState),
                         {#delta { start_seq_id = Limit,
                                   count        = Len,
                                   end_seq_id   = MaxSeqId + 1 },
                          Qc, RamIndexCount1, IndexState1}
            end
    end.

push_betas_to_deltas(Generator, Limit, Q, Count, RamIndexCount, IndexState) ->
    case Generator(Q) of
        {empty, _Q} ->
            {Count, Q, RamIndexCount, IndexState};
        {{value, _IndexOnDisk, #msg_status { seq_id = SeqId }}, _Qa}
          when SeqId < Limit ->
            {Count, Q, RamIndexCount, IndexState};
        {{value, IndexOnDisk, MsgStatus}, Qa} ->
            {RamIndexCount1, IndexState1} =
                case IndexOnDisk of
                    true  -> {RamIndexCount, IndexState};
                    false -> {#msg_status { index_on_disk = true },
                              IndexState2} =
                                 maybe_write_index_to_disk(true, MsgStatus,
                                                           IndexState),
                             {RamIndexCount - 1, IndexState2}
                end,
            push_betas_to_deltas(
              Generator, Limit, Qa, Count + 1, RamIndexCount1, IndexState1)
    end.
