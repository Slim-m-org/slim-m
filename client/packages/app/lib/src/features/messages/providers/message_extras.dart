// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reactions, attachments, polls and thread summaries, held in memory rather
/// than in the local database: every REST fetch carries them in full, so a
/// restart rehydrates them without a schema change.
///
/// A live frame omits them, so [applyMessage] merges and never erases; only a
/// fetched page ([applyMessages]) may clear reactions. [retain] drops whatever
/// no open channel holds, in one write so a message on screen never loses its
/// reactions mid-render, and [clear] empties it on sign-out.
///
/// [applyPage] also records which seqs a page covered, and [retain] and
/// [clear] forget that with the extras it describes.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import 'hydrated_ranges.dart';
import 'message_extras_model.dart';
import 'poll_local_vote.dart';

export 'message_extras_model.dart';

class MessageExtrasController
    extends StateNotifier<Map<String, MessageExtras>> {
  MessageExtrasController(this._ref) : super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen(_onEvent);
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;
  final _hydrated = <String, HydratedRanges>{};

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
      case api.PollVoted(:final messageId, :final options, :final runoff):
        _applyPollTally(messageId, options, runoff);
      case api.MessageComponentsChanged(:final messageId, :final components):
        _set(messageId, extrasFor(messageId).copyWith(components: components));
      case api.MessageEmbedsChanged(:final messageId, :final embeds):
        _set(messageId, extrasFor(messageId).copyWith(embeds: embeds));
      case api.MessageLinkPreviewsRemoved(:final messageId):
        _unconfirmedRemovals.remove(messageId);
        _set(
          messageId,
          extrasFor(messageId).copyWith(linkPreviewsRemoved: true),
        );
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

  final _unconfirmedRemovals = <String>{};

  /// Hides [messageId]'s cards before the server answers.
  void beginLocalLinkPreviewsRemoval(String messageId) {
    _unconfirmedRemovals.add(messageId);
    _set(messageId, extrasFor(messageId).copyWith(linkPreviewsRemoved: true));
  }

  /// The server answered the removal; nothing is left to roll back.
  void confirmLocalLinkPreviewsRemoval(String messageId) =>
      _unconfirmedRemovals.remove(messageId);

  /// Restores the cards after a refused removal, unless a frame or a fetch has
  /// since confirmed the removal, in which case they stay hidden. Whether it rolled back.
  bool rollBackLocalLinkPreviewsRemoval(String messageId) {
    if (!_unconfirmedRemovals.remove(messageId)) return false;
    _set(messageId, extrasFor(messageId).copyWith(linkPreviewsRemoved: false));
    return true;
  }

  /// Merges in whatever [message] carries. See the file doc comment for why
  /// a merge, never an overwrite, is what makes this safe to call from a
  /// live socket frame that may have omitted all three fields.
  void applyMessage(api.Message message) {
    if (message.linkPreviewsRemoved) _unconfirmedRemovals.remove(message.id);
    _set(message.id, _merged(message, state[message.id]));
  }

  /// Applies a fetched page in one state write. A fetch is authoritative for
  /// reactions, so an empty list clears a tally removed while away; the other
  /// fields still merge, so a slower fetch cannot undo a live thread update.
  void applyMessages(Iterable<api.Message> messages) {
    final next = {...state};
    var changed = false;
    for (final message in messages) {
      if (message.linkPreviewsRemoved) _unconfirmedRemovals.remove(message.id);
      next[message.id] = _merged(
        message,
        next[message.id],
        authoritative: true,
      );
      changed = true;
    }
    if (changed) state = next;
  }

  /// [applyMessages] for a page fetched below [before] (the newest when null),
  /// recording the seqs it covered: to its oldest row, or the start if short.
  void applyPage(
    String channelId,
    List<api.Message> page, {
    required int? before,
    required int limit,
  }) {
    applyMessages(page);
    final top = before == null ? HydratedRanges.newest : before - 1;
    final oldest = page.length < limit
        ? 0
        : page.map((m) => m.seq).reduce(math.min);
    final ranges = _hydrated.putIfAbsent(channelId, HydratedRanges.new);
    ranges.add(math.min(oldest, top), top);
  }

  /// The highest seq at or above [floor] no page covered; see [HydratedRanges].
  int? highestUnhydrated(String channelId, int floor) =>
      (_hydrated[channelId] ?? HydratedRanges()).highestGap(floor);

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
    reactions: _list(
      message.reactions,
      existing?.reactions,
      replace: authoritative,
    ),
    attachments: _list(message.attachments, existing?.attachments),
    // Same rule as reactions: a REST fetch replaces; a bare live frame (no code_runs) cannot clobber a result already held.
    codeRuns: _list(
      message.codeRuns,
      existing?.codeRuns,
      replace: authoritative,
    ),
    poll: message.poll ?? existing?.poll,
    appSurface: message.appSurface ?? existing?.appSurface,
    call: message.call ?? existing?.call,
    // Same rule as components: a bot can replace or clear them, so a REST fetch replaces.
    embeds: _list(message.embeds, existing?.embeds, replace: authoritative),
    webhookUsername: message.webhookUsername ?? existing?.webhookUsername,
    viaModule: message.viaModule ?? existing?.viaModule,
    // Same rule as reactions: a REST fetch replaces, so buttons a bot cleared while this client was away go.
    components: _list(
      message.components,
      existing?.components,
      replace: authoritative,
    ),
    threadChannelId: message.threadChannelId ?? existing?.threadChannelId,
    threadReplyCount: message.threadReplyCount ?? existing?.threadReplyCount,
    threadLastReplyAt: message.threadLastReplyAt ?? existing?.threadLastReplyAt,
    threadUnreadCount: message.threadUnreadCount ?? existing?.threadUnreadCount,
    // Only REST pages carry it per viewer; the author's own send and edit responses say false.
    mentionsMe: authoritative
        ? message.mentionsMe
        : message.mentionsMe || (existing?.mentionsMe ?? false),
    linkPreviewsRemoved:
        message.linkPreviewsRemoved || (existing?.linkPreviewsRemoved ?? false),
  );

  static List<T> _list<T>(
    List<T> fresh,
    List<T>? known, {
    bool replace = false,
  }) {
    if (replace || fresh.isNotEmpty) return fresh;
    return known ?? const [];
  }

  /// Replaces the cached tallies from a broadcast, carrying `reacted` over from
  /// what this client already knew: it is per-viewer and never broadcast (see
  /// [api.ReactionTally]'s own doc), so it has to be preserved, not guessed.
  void _applyReactionsChanged(
    String messageId,
    List<api.ReactionTally> tallies,
  ) {
    final known = extrasFor(messageId).reactions;
    // any() rather than firstWhere(orElse:): a covariant List<Never> here threw on the orElse closure (iOS log, 2026-10-22).
    final next = [
      for (final tally in tallies)
        api.ReactionSummary(
          emoji: tally.emoji,
          count: tally.count,
          reacted: known.any((r) => r.emoji == tally.emoji && r.reacted),
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
    // threadUnreadCount is kept: no per-viewer answer rides this frame, see its own doc comment.
    _set(
      parentMessageId,
      extrasFor(parentMessageId).copyWith(
        threadChannelId: threadChannelId,
        threadReplyCount: replyCount,
        threadLastReplyAt: lastReplyAt,
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
    final next = active
        ? _withReaction(existing, emoji, index)
        : _withoutReaction(existing, index);
    _set(messageId, extrasFor(messageId).copyWith(reactions: next));
  }

  List<api.ReactionSummary> _withReaction(
    List<api.ReactionSummary> existing,
    String emoji,
    int index,
  ) {
    final next = [...existing];
    if (index < 0) {
      return next
        ..add(api.ReactionSummary(emoji: emoji, count: 1, reacted: true));
    }
    final current = next[index];
    if (current.reacted) return next;
    next[index] = api.ReactionSummary(
      emoji: emoji,
      count: current.count + 1,
      reacted: true,
    );
    return next;
  }

  List<api.ReactionSummary> _withoutReaction(
    List<api.ReactionSummary> existing,
    int index,
  ) {
    final next = [...existing];
    if (index < 0) return next;
    final current = next[index];
    final count = current.reacted ? current.count - 1 : current.count;
    if (count <= 0) {
      next.removeAt(index);
    } else {
      next[index] = api.ReactionSummary(
        emoji: current.emoji,
        count: count,
        reacted: false,
      );
    }
    return next;
  }

  /// Merges a broadcast tally into the cached poll, dropping it when no poll is
  /// known yet: a bare tally carries neither the question nor the option
  /// labels, so there is nothing to merge it into until some REST fetch has
  /// taught this cache those. The next fetch including this message picks it up.
  void _applyPollTally(
    String messageId,
    List<api.PollOptionTally> tallies,
    api.PollRunoff? runoff,
  ) {
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
        poll: poll.copyWith(
          options: options,
          totalVotes: options.fold<int>(0, (sum, o) => sum + o.votes),
          runoff: runoff,
        ),
      ),
    );
  }

  /// Records the caller's own vote immediately, ahead of the `poll.voted`
  /// broadcast: that event never reports back who cast a vote, only the
  /// refreshed tally, so [Poll.votedOption] (per-viewer, never broadcast)
  /// would otherwise never update on the voter's own screen at all.
  void applyLocalVote(String messageId, int option, {List<int>? ranking}) {
    final poll = extrasFor(messageId).poll;
    if (poll == null) return;
    final next = pollAfterLocalVote(poll, option, ranking: ranking);
    if (next != null) _setPoll(messageId, next);
  }

  /// Takes back a vote the server refused; see [pollAfterRevertedVote].
  void revertLocalVote(
    String messageId, {
    required api.Poll before,
    required api.Poll applied,
  }) {
    final poll = extrasFor(messageId).poll;
    if (poll == null) return;
    _setPoll(
      messageId,
      pollAfterRevertedVote(before: before, applied: applied, current: poll),
    );
  }

  void _setPoll(String messageId, api.Poll poll) =>
      _set(messageId, extrasFor(messageId).copyWith(poll: poll));

  void _set(String id, MessageExtras extras) {
    state = {...state, id: extras};
  }

  /// Drops every cached entry. See the file doc comment for why sign-out is
  /// the one point this runs.
  void clear() {
    _hydrated.clear();
    if (state.isEmpty) return;
    state = const {};
  }

  /// Drops every entry whose id is not in [reachable]. See the file doc
  /// comment for why this, not a per-id prune, is the safe way to bound this
  /// map - only ever called from `providers/retention_sweep.dart`'s periodic
  /// sweep, with [reachable] already computed off the local store.
  void retain(Set<String> reachable, {required Set<String> openChannelIds}) {
    _hydrated.removeWhere(
      (channelId, _) => !openChannelIds.contains(channelId),
    );
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
