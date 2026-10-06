// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The presentational pieces the transcript composes but that carry no list
/// logic of their own: the start-of-channel header, what stands in its place
/// while there is still history above, what an empty list means, the one-shot
/// entrance a freshly arrived message rides in on, and the per-row extras
/// scope.
///
/// Split out of `message_transcript.dart` to keep that file to the reversed
/// scroll and the grouping, unread and day rules that decide what each row
/// shows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/message_editing.dart';
import '../providers/message_extras.dart';
import '../providers/sync_controller.dart';
import '../routing/breakpoints.dart';

/// The block at the very top of a channel's history: a mark, the channel's
/// name, and its topic if it has one. It fills what would otherwise be a wide
/// empty band above a short conversation (the list is bottom-anchored), and is
/// the one place the channel topic is shown in the body.
///
/// A thread takes a different, compact form entirely rather than the same sentence with
/// a name substituted in: one quiet line under the parent message, since the
/// parent already says what the thread is about. A thread channel is stored with an empty `name`
/// (`Store::open_thread` inserts `''`, since a thread has no name of its
/// own), so the channel wording rendered as a welcome to a channel called
/// nothing, and read as one called "Thread". What a person opening an empty
/// thread needs to know is that replies go here, which is what [isThread]
/// says instead.
///
/// [name] is null for a DM: its "name" is a person, so this deliberately
/// never says "Welcome to #" over somebody's own name. It renders generic
/// copy instead of nothing, which `message_transcript.dart`'s own doc
/// comment on `_topSlot` explains: a DM reaching its true start used to
/// vanish outright rather than swap, the one case that broke the invariant
/// [HistoryTopAffordance] documents below.
class ChannelStartHeader extends StatelessWidget {
  const ChannelStartHeader({
    super.key,
    required this.name,
    this.topic,
    this.isThread = false,
    this.isVoice = false,
  });

  final String? name;
  final String? topic;

  /// Whether this is a thread's own transcript rather than a channel's.
  final bool isThread;

  /// A voice channel's chat: [name] is its name, shown without a hash.
  final bool isVoice;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // The message rows' own gutter, so the block left-aligns with them.
    final gutter = paneGutterOf(context);
    final name = this.name;
    if (isThread) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          gutter,
          AppSpacing.s12,
          gutter,
          AppSpacing.s8,
        ),
        child: Text(
          'No replies yet',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        AppSpacing.s24,
        gutter,
        AppSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isVoice
                  ? AppIcons.voice
                  : name != null
                  ? AppIcons.hash
                  : AppIcons.members,
              size: 26,
              color: tokens.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          Text(
            isVoice && name != null
                ? 'Chat for $name'
                : name != null
                ? 'Welcome to #$name'
                : 'This is the start of your conversation.',
            style: AppText.title.copyWith(color: tokens.textPrimary),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(switch (name) {
            final String n when isVoice =>
              topic ??
                  'This is the start of the chat for the $n voice channel.',
            final String n => topic ?? 'This is the start of the #$n channel.',
            null => 'Messages sent here are just between the two of you.',
          }, style: AppText.body.copyWith(color: tokens.textSecondary)),
        ],
      ),
    );
  }
}

/// What sits above the oldest loaded message while the channel's real start
/// has not been reached: a neutral note that there is more, or the failure of
/// the page that was meant to fetch it.
///
/// It stands exactly where [ChannelStartHeader] would, which is the point.
/// Announcing the start of a conversation above history nobody has fetched is
/// a claim the client cannot make, and a blank gap there reads as the same
/// claim more quietly.
class HistoryTopAffordance extends StatelessWidget {
  const HistoryTopAffordance({
    super.key,
    required this.failed,
    required this.loading,
    this.onRetry,
  });

  final bool failed;

  /// Whether a page is actually in flight right now. Not the opposite of
  /// [failed]: once a filtered-empty view stops driving the automatic
  /// trigger (see `message_transcript.dart`'s own note on that), this sits
  /// idle - between pages, or waiting on a scroll that has not come again -
  /// and the copy has to say so rather than claim a fetch that is not
  /// running.
  final bool loading;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final gutter = paneGutterOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        AppSpacing.s16,
        gutter,
        AppSpacing.s8,
      ),
      child: failed
          ? AppErrorState(
              message: 'Could not load earlier messages.',
              onRetry: onRetry,
            )
          : loading
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.s8),
                Text(
                  'Loading earlier messages...',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            )
          : Text(
              'There is more history above.',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
    );
  }
}

/// A one-shot fade-and-rise for a freshly arrived message. Keyed by the newest
/// id by its caller, so a new arrival remounts and plays while a rebuild with
/// the same id reuses the running animation rather than cutting it. Reads
/// reduce-motion once, on first layout, and lands instantly if set.
class MessageEntrance extends StatefulWidget {
  const MessageEntrance({
    super.key,
    required this.child,
    required this.animateOnMount,
  });

  final Widget child;
  final bool animateOnMount;

  @override
  State<MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.base,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.animateOnMount && !AppMotion.isReduced(context)) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final t = AppMotion.entrance.transform(_controller.value);
      return Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 8),
          child: child,
        ),
      );
    },
  );
}

/// What an empty message list means depends on whether catch-up has actually
/// run: a channel can look empty because it is, or because sync has not
/// reached it yet, and those read as opposite things to the person waiting.
class EmptyMessages extends StatelessWidget {
  const EmptyMessages({super.key, required this.syncStatus});

  final SyncStatus syncStatus;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return switch (syncStatus) {
      SyncStatus.connecting => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: AppSpacing.s12),
            Text(
              'Catching up on messages...',
              style: TextStyle(color: tokens.textSecondary),
            ),
          ],
        ),
      ),
      SyncStatus.offline => Center(
        child: Text(
          'Offline. Messages will appear once reconnected.',
          textAlign: TextAlign.center,
          style: TextStyle(color: tokens.textSecondary),
        ),
      ),
      SyncStatus.live => Center(
        child: Text(
          'No messages yet.',
          style: TextStyle(color: tokens.textSecondary),
        ),
      ),
    };
  }
}

/// One row's reactions, attachments, poll and edit-in-progress flag, watched
/// for that message id alone.
///
/// The screen used to watch [messageExtrasProvider] whole and hand the map
/// down, so one reaction anywhere rebuilt the entire transcript, and opening a
/// channel did that once per hydrated message. Selecting by id means a change
/// reaches the one row it is about.
///
/// [editing] joined the same selector rather than staying a `MessageTranscript`
/// constructor parameter for the identical reason: that used to be a plain
/// field on `_ChannelScreenState`, so starting or cancelling an edit rebuilt
/// every visible row's markdown, not only the one whose flag actually flipped.
class MessageRowExtras extends ConsumerWidget {
  const MessageRowExtras({
    super.key,
    required this.messageId,
    required this.channelId,
    required this.builder,
    this.previousMessageId,
  });

  final String messageId;
  final String channelId;

  /// The row visually above, so [builder] can tell a username change from a continuation.
  final String? previousMessageId;
  final Widget Function(
    MessageExtras extras,
    bool editing,
    String? previousWebhookUsername,
  )
  builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => builder(
    ref.watch(
      messageExtrasProvider.select(
        (extras) => extras[messageId] ?? MessageExtras.empty,
      ),
    ),
    ref.watch(
      editingMessageIdProvider(channelId).select((id) => id == messageId),
    ),
    ref.watch(
      messageExtrasProvider.select(
        (extras) => extras[previousMessageId]?.webhookUsername,
      ),
    ),
  );
}
