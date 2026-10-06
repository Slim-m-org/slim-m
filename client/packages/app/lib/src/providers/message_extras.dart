// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reactions, attachments, polls, and a thread reply summary, kept in memory
/// rather than in the local database.
///
/// `client/packages/data` has no columns for any of the four, and this is
/// deliberate rather than an oversight: every REST fetch that returns a
/// [api.Message] (send, list, sync, search) already carries all four in
/// full, so re-fetching the channel's recent messages on open (see
/// [ChannelScreen]) re-hydrates this cache correctly after a restart without
/// a schema migration. What would not survive a restart cleanly is any
/// state this cache holds that a REST fetch cannot reconstruct - and there
/// is none: even a locally-cast vote or reaction is only ever an optimistic
/// preview of what the next broadcast or fetch confirms anyway.
///
/// The one hazard this exists to guard against: the server builds a live
/// `message.created`/`message.edited` frame from a bare DTO that omits
/// reactions, attachments, poll, and thread data (a known Phase 4 server gap
/// this client must not try to fix). [applyMessage] merges rather than
/// overwrites, so that omission can only ever fail to add new information -
/// it can never erase a better answer this cache already has cached from a
/// REST fetch. The one field a REST fetch is authoritative enough to shrink is
/// reactions, so [applyMessages] alone lets an empty reaction list win - that
/// is what lets a reaction removed back to zero actually clear. A thread
/// opening, or gaining a reply, reaches an already-open
/// channel live through `Event::ThreadUpdated` instead - see
/// [_applyThreadUpdated] - which closes the gap
/// `docs/decisions/0005-threads.md` once named for `thread_channel_id`.
///
/// Nothing used to prune one entry at a time, because no consumer had a
/// reachability answer to prune against: search, pins, the command palette
/// and the transcript's own paged window all render extras for messages
/// outside any one channel's visible rows, and an over-eager prune shows a
/// message with its reactions missing until some later fetch happens to
/// include it again, which is worse than the memory. [retain] is the bulk
/// answer `providers/retention_sweep.dart` now has for that question - every
/// id still held for a channel some `ChannelScreen` has open right now, which
/// covers every one of those four surfaces because none of them can render a
/// message from a channel that is not open (see that file's own doc for why).
/// It drops everything else in one state write, never one id at a time,
/// which is what keeps a message still on screen from ever losing its
/// reactions mid-render the way a per-id prune risked.
///
/// That memory is real, not free: each entry retains a reaction list, an
/// attachment list and a poll, and history pagination
/// (`providers/channel_history.dart`) can now pull thousands of messages
/// through [MessageExtrasController.applyMessages] in one session. [clear] is
/// the one point this does get dropped in bulk, on sign-out
/// (`SyncController._endSession`), for the same reason the message store
/// itself is wiped there: the local database is one file for the whole app,
/// and whoever signs in next on this device must not still find a stranger's
/// reactions cached.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'live_events.dart';

/// One message's reactions, attachments, poll, and thread reply summary,
/// however much of each is known so far.
class MessageExtras {
  const MessageExtras({
    this.reactions = const [],
    this.attachments = const [],
    this.codeRuns = const [],
    this.poll,
    this.appSurface,
    this.call,
    this.embeds = const [],
    this.webhookUsername,
    this.components = const [],
    this.threadChannelId,
    this.threadReplyCount,
    this.threadLastReplyAt,
    this.threadUnreadCount,
  });

  final List<api.ReactionSummary> reactions;
  final List<api.Attachment> attachments;

  /// Fixed once a message exists, like [attachments]; see decision 0030.
  final List<api.Embed> embeds;

  /// A webhook post's own username label; fixed once the message exists.
  final String? webhookUsername;

  /// A bot's buttons. Unlike [embeds] a bot can replace or clear them, so a
  /// REST fetch and a `message.components` frame both replace the list, where
  /// a bare live create or edit frame only ever adds.
  final List<api.ComponentRow> components;

  /// The shared result of each fenced code block run in this message, one
  /// entry per block, ordered by block index. Follows [reactions]' merge
  /// rule: a REST fetch replaces the list, a bare live frame cannot clobber
  /// it, and a `code_run.changed` broadcast replaces the one block's entry.
  final List<api.CodeRun> codeRuns;
  final api.Poll? poll;

  /// The app this message launches, or null when it launches none. Fixed once
  /// the message exists, like [poll]; its live surface state rides [codeRuns]
  /// at block 0.
  final api.AppSurface? appSurface;

  /// The call this message records, or null on an ordinary message. Fixed
  /// once the message exists, like [appSurface]: a call reaches a terminal
  /// state exactly once and nothing edits it afterwards.
  final api.CallRecord? call;

  /// The thread opened from this message, or null if none is known yet -
  /// same four fields, same merge rule, as [api.Message] carries them.
  final String? threadChannelId;
  final int? threadReplyCount;
  final int? threadLastReplyAt;

  /// How many of the thread's live messages this viewer has not yet read,
  /// or null exactly when [threadChannelId] is null. Only ever set from a
  /// REST fetch: a live `ThreadUpdated` frame carries no per-viewer answer
  /// (see [_applyThreadUpdated]), so this is left as whatever the last
  /// fetch established until the next one corrects it.
  final int? threadUnreadCount;

  MessageExtras copyWith({
    List<api.ReactionSummary>? reactions,
    List<api.Attachment>? attachments,
    List<api.CodeRun>? codeRuns,
    api.Poll? poll,
    api.AppSurface? appSurface,
    api.CallRecord? call,
    List<api.ComponentRow>? components,
  }) => MessageExtras(
    reactions: reactions ?? this.reactions,
    attachments: attachments ?? this.attachments,
    codeRuns: codeRuns ?? this.codeRuns,
    poll: poll ?? this.poll,
    appSurface: appSurface ?? this.appSurface,
    call: call ?? this.call,
    embeds: embeds,
    webhookUsername: webhookUsername,
    components: components ?? this.components,
    threadChannelId: threadChannelId,
    threadReplyCount: threadReplyCount,
    threadLastReplyAt: threadLastReplyAt,
    threadUnreadCount: threadUnreadCount,
  );

  static const empty = MessageExtras();
}

class MessageExtrasController
    extends StateNotifier<Map<String, MessageExtras>> {
  MessageExtrasController(this._ref) : super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen(_onEvent);
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;

  MessageExtras extrasFor(String messageId) =>
      state[messageId] ?? MessageExtras.empty;

  void _onEvent(api.ServerEvent event) {
    switch (event) {
      case api.MessageCreated(:final message):
        applyMessage(message);
      case api.MessageEdited(:final message):
        applyMessage(message);
      case api.ReactionsChanged(:final messageId, :final reactions):
        _applyReactionsChanged(messageId, reactions);
      case api.CodeRunChanged(:final messageId, :final run):
        applyCodeRun(messageId, run);
      case api.CodeRunsCleared(:final messageId):
        _applyCodeRunsCleared(messageId);
      case api.PollVoted(:final messageId, :final options):
        _applyPollTally(messageId, options);
      case api.MessageComponentsChanged(:final messageId, :final components):
        _set(messageId, extrasFor(messageId).copyWith(components: components));
      case api.ThreadUpdated(
        :final parentMessageId,
        :final threadChannelId,
        :final replyCount,
        :final lastReplyAt,
      ):
        _applyThreadUpdated(
          parentMessageId,
          threadChannelId: threadChannelId,
          replyCount: replyCount,
          lastReplyAt: lastReplyAt,
        );
      default:
        break;
    }
  }

  /// Merges in whatever [message] carries. See the file doc comment for why
  /// a merge, never an overwrite, is what makes this safe to call from a
  /// live socket frame that may have omitted all three fields.
  void applyMessage(api.Message message) =>
      _set(message.id, _merged(message, state[message.id]));

  /// For a REST fetch's whole page at once (a channel screen hydrating its
  /// visible window on open, or a page of older history).
  ///
  /// This fetch is authoritative for reactions - it enriches them in full and
  /// per-viewer - so unlike [applyMessage] it lets an empty reaction list win,
  /// clearing a reaction that was removed back to zero while this client was
  /// away. Without that, a live frame's merge could never fall through to an
  /// empty list and the stale tally would show forever (CQ3). The other fields
  /// still merge: a poll and an attachment set are fixed once a message
  /// exists, and a thread's reply count only climbs, so `??` on those can only
  /// ever add - and, unlike a blanket replace, a slower fetch that predates a
  /// live `ThreadUpdated` cannot null a freshly-opened thread's affordance back
  /// out again (it would not reappear until the next reply or reload).
  ///
  /// One state write for the whole page, deliberately: this used to call
  /// [applyMessage] in a loop, so hydrating a 50-message window published 50
  /// successive whole-map copies and rebuilt every listener 50 times for one
  /// fetch.
  void applyMessages(Iterable<api.Message> messages) {
    final next = {...state};
    var changed = false;
    for (final message in messages) {
      next[message.id] = _merged(
        message,
        next[message.id],
        authoritative: true,
      );
      changed = true;
    }
    if (changed) state = next;
  }

  /// Whatever [message] carries, over whatever is already known. See the file
  /// doc comment for why this can only ever add information; the three
  /// thread fields follow [poll]'s own rule for the same reason - a bare live
  /// frame carries none of them, so `??` can only add, never clobber.
  ///
  /// [authoritative] is set only by [applyMessages]: a REST fetch's empty
  /// reaction list means every reaction is gone and must replace, where a live
  /// frame's empty one only means the frame omitted them.
  MessageExtras _merged(
    api.Message message,
    MessageExtras? existing, {
    bool authoritative = false,
  }) => MessageExtras(
    reactions: authoritative || message.reactions.isNotEmpty
        ? message.reactions
        : existing?.reactions ?? const [],
    attachments: message.attachments.isNotEmpty
        ? message.attachments
        : existing?.attachments ?? const [],
    // Same rule as reactions: a REST fetch replaces; a bare live frame (no code_runs) cannot clobber a result already held.
    codeRuns: authoritative || message.codeRuns.isNotEmpty
        ? message.codeRuns
        : existing?.codeRuns ?? const [],
    poll: message.poll ?? existing?.poll,
    appSurface: message.appSurface ?? existing?.appSurface,
    call: message.call ?? existing?.call,
    embeds: message.embeds.isNotEmpty
        ? message.embeds
        : existing?.embeds ?? const [],
    webhookUsername: message.webhookUsername ?? existing?.webhookUsername,
    // Same rule as reactions: a REST fetch replaces, so buttons a bot cleared while this client was away go.
    components: authoritative || message.components.isNotEmpty
        ? message.components
        : existing?.components ?? const [],
    threadChannelId: message.threadChannelId ?? existing?.threadChannelId,
    threadReplyCount: message.threadReplyCount ?? existing?.threadReplyCount,
    threadLastReplyAt: message.threadLastReplyAt ?? existing?.threadLastReplyAt,
    threadUnreadCount: message.threadUnreadCount ?? existing?.threadUnreadCount,
  );

  /// Replaces the cached tallies from a broadcast, carrying `reacted` over from
  /// what this client already knew: it is per-viewer and never broadcast (see
  /// [api.ReactionTally]'s own doc), so it has to be preserved, not guessed.
  void _applyReactionsChanged(
    String messageId,
    List<api.ReactionTally> tallies,
  ) {
    final known = extrasFor(messageId).reactions;
    const unknown = api.ReactionSummary(emoji: '', count: 0, reacted: false);
    final next = [
      for (final tally in tallies)
        api.ReactionSummary(
          emoji: tally.emoji,
          count: tally.count,
          reacted: known
              .firstWhere((r) => r.emoji == tally.emoji, orElse: () => unknown)
              .reacted,
        ),
    ];
    _set(messageId, extrasFor(messageId).copyWith(reactions: next));
  }

  /// Replaces the one block's shared result from a broadcast, so everyone
  /// viewing sees a run someone else triggered without rerunning it. Keyed by
  /// block index; a re-run of the same block overwrites its entry. Also the
  /// runner's own POST response, so the output shows without the broadcast.
  void applyCodeRun(String messageId, api.CodeRun run) {
    final existing = extrasFor(messageId).codeRuns;
    final next = [
      for (final r in existing)
        if (r.blockIndex != run.blockIndex) r,
      run,
    ]..sort((a, b) => a.blockIndex.compareTo(b.blockIndex));
    _set(messageId, extrasFor(messageId).copyWith(codeRuns: next));
  }

  /// Drops every cached run for a message whose content just changed: the
  /// explicit signal [api.CodeRunsCleared]'s own doc explains a bare
  /// `message.edited` frame cannot give, since [_merged] only ever adds to
  /// what this cache already holds. No block index to key off, on purpose -
  /// see that event's doc for why the whole message clears at once.
  void _applyCodeRunsCleared(String messageId) {
    _set(messageId, extrasFor(messageId).copyWith(codeRuns: const []));
  }

  /// A thread just opened, or gained a reply: what makes the "N replies"
  /// affordance appear, or its count move, on a screen nobody reloaded.
  /// Never reduces `replyCount`: the server publishes this only for a fresh
  /// open or a fresh send, both of which move the count forward, and a
  /// delete does not currently republish one - see
  /// `docs/decisions/0005-threads.md`.
  void _applyThreadUpdated(
    String parentMessageId, {
    required String threadChannelId,
    required int replyCount,
    required int? lastReplyAt,
  }) {
    final existing = extrasFor(parentMessageId);
    _set(
      parentMessageId,
      MessageExtras(
        reactions: existing.reactions,
        attachments: existing.attachments,
        codeRuns: existing.codeRuns,
        poll: existing.poll,
        embeds: existing.embeds,
        webhookUsername: existing.webhookUsername,
        components: existing.components,
        threadChannelId: threadChannelId,
        threadReplyCount: replyCount,
        threadLastReplyAt: lastReplyAt,
        // No per-viewer answer rides this frame; see threadUnreadCount's own doc comment.
        threadUnreadCount: existing.threadUnreadCount,
      ),
    );
  }

  /// Applies the caller's own reaction toggle immediately, ahead of the
  /// `reactions.changed` broadcast that eventually confirms it (the acting
  /// connection receives its own broadcast too, so this is a preview, not a
  /// permanent guess). Reverting on a failed request is the caller's job,
  /// by calling this again with [active] flipped.
  void applyLocalReactionToggle(String messageId, String emoji, bool active) {
    final existing = extrasFor(messageId).reactions;
    final index = existing.indexWhere((r) => r.emoji == emoji);
    final List<api.ReactionSummary> next;
    if (active) {
      next = [...existing];
      if (index >= 0) {
        final current = next[index];
        if (!current.reacted) {
          next[index] = api.ReactionSummary(
            emoji: emoji,
            count: current.count + 1,
            reacted: true,
          );
        }
      } else {
        next.add(api.ReactionSummary(emoji: emoji, count: 1, reacted: true));
      }
    } else {
      next = [...existing];
      if (index >= 0) {
        final current = next[index];
        final count = current.reacted ? current.count - 1 : current.count;
        if (count <= 0) {
          next.removeAt(index);
        } else {
          next[index] = api.ReactionSummary(
            emoji: emoji,
            count: count,
            reacted: false,
          );
        }
      }
    }
    _set(messageId, extrasFor(messageId).copyWith(reactions: next));
  }

  /// Merges a broadcast tally into the cached poll, dropping it when no poll is
  /// known yet: a bare tally carries neither the question nor the option
  /// labels, so there is nothing to merge it into until some REST fetch has
  /// taught this cache those. The next fetch including this message picks it up.
  void _applyPollTally(String messageId, List<api.PollOptionTally> tallies) {
    final poll = extrasFor(messageId).poll;
    if (poll == null) return;
    final byPosition = {for (final t in tallies) t.position: t.votes};
    final options = [
      for (final option in poll.options)
        api.PollOption(
          position: option.position,
          label: option.label,
          votes: byPosition[option.position] ?? option.votes,
        ),
    ];
    _set(
      messageId,
      extrasFor(messageId).copyWith(
        poll: api.Poll(
          question: poll.question,
          options: options,
          totalVotes: options.fold(0, (sum, o) => sum + o.votes),
          votedOption: poll.votedOption,
          closeAt: poll.closeAt,
          closed: poll.closed,
        ),
      ),
    );
  }

  /// Records the caller's own vote immediately, ahead of the `poll.voted`
  /// broadcast: that event never reports back who cast a vote, only the
  /// refreshed tally, so [Poll.votedOption] (per-viewer, never broadcast)
  /// would otherwise never update on the voter's own screen at all.
  void applyLocalVote(String messageId, int option) {
    final poll = extrasFor(messageId).poll;
    if (poll == null) return;
    final previous = poll.votedOption;
    if (previous == option) return;
    final options = [
      for (final o in poll.options)
        if (o.position == option)
          api.PollOption(
            position: o.position,
            label: o.label,
            votes: o.votes + 1,
          )
        else if (o.position == previous)
          api.PollOption(
            position: o.position,
            label: o.label,
            votes: (o.votes - 1).clamp(0, 1 << 31),
          )
        else
          o,
    ];
    _set(
      messageId,
      extrasFor(messageId).copyWith(
        poll: api.Poll(
          question: poll.question,
          options: options,
          totalVotes: options.fold(0, (sum, o) => sum + o.votes),
          votedOption: option,
          closeAt: poll.closeAt,
          closed: poll.closed,
        ),
      ),
    );
  }

  void _set(String id, MessageExtras extras) {
    state = {...state, id: extras};
  }

  /// Drops every cached entry. See the file doc comment for why sign-out is
  /// the one point this runs.
  void clear() {
    if (state.isEmpty) return;
    state = const {};
  }

  /// Drops every entry whose id is not in [reachable]. See the file doc
  /// comment for why this, not a per-id prune, is the safe way to bound this
  /// map - only ever called from `providers/retention_sweep.dart`'s periodic
  /// sweep, with [reachable] already computed off the local store.
  void retain(Set<String> reachable) {
    if (state.keys.every(reachable.contains)) return;
    state = {
      for (final entry in state.entries)
        if (reachable.contains(entry.key)) entry.key: entry.value,
    };
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

final messageExtrasProvider =
    StateNotifierProvider<MessageExtrasController, Map<String, MessageExtras>>(
      (ref) => MessageExtrasController(ref),
    );
