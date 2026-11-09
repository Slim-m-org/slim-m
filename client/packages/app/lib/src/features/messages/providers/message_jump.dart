// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Jumping to a message from search or from the pins sheet: paging a
/// channel's history backwards until the target is loaded locally, or
/// giving up within a bound rather than paging forever.
///
/// Kept apart from `channel_history.dart`: that file owns one channel's
/// paging state, and this is the one-shot "find this specific message"
/// question layered over it, driven from wherever a message id is tapped
/// rather than from the transcript itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' show MessageStore;

import '../../channels/providers/channel_history.dart';
import 'message_page_size.dart';
import 'retention_policy.dart';
import '../../../providers/providers.dart';

/// What a jump is doing right now.
sealed class MessageJumpState {
  const MessageJumpState();
}

class MessageJumpIdle extends MessageJumpState {
  const MessageJumpIdle();
}

/// Paging backwards, looking for [messageId] in [channelId].
class MessageJumpSeeking extends MessageJumpState {
  const MessageJumpSeeking(this.channelId, this.messageId, this.token);
  final String channelId;
  final String messageId;
  final int token;
}

/// The message is loaded locally. `MessageTranscript` consumes this exactly
/// once, by scrolling to the row and flashing it, then calls
/// [MessageJumpController.consume] with [token] - never inferred from the
/// state going idle on its own, since a stale rebuild must not repeat either.
class MessageJumpArrived extends MessageJumpState {
  const MessageJumpArrived(this.channelId, this.messageId, this.token);
  final String channelId;
  final String messageId;
  final int token;
}

/// Paging never turned the message up within the bound. Whoever asked for the
/// jump says so plainly; a silent no-op is the one outcome worth avoiding
/// here.
class MessageJumpUnreachable extends MessageJumpState {
  const MessageJumpUnreachable(this.channelId, this.messageId, this.token);
  final String channelId;
  final String messageId;
  final int token;
}

/// Paging stopped because a page of history could not be fetched, so nothing
/// is known about whether the message exists.
class MessageJumpFailed extends MessageJumpState {
  const MessageJumpFailed(this.channelId, this.messageId, this.token);
  final String channelId;
  final String messageId;
  final int token;
}

enum _Paged { more, stop, failed }

/// Drives one jump at a time. A later [jumpTo] call always wins: its token
/// invalidates whatever loop an earlier call is still running, so two taps in
/// quick succession cannot have the first one's page finish and overwrite the
/// second's result.
class MessageJumpController extends StateNotifier<MessageJumpState> {
  MessageJumpController(this._ref) : super(const MessageJumpIdle());

  final Ref _ref;
  int _token = 0;

  /// Pages needed to fill a full transcript window, which is as far back as a
  /// jump can ever show anything: the store keeps no more than
  /// [channelWindowCeiling] rows per channel. Counted in messages, so the
  /// page-size setting changes how many requests that takes, not how far a
  /// jump reaches.
  int get _maxPages {
    final rows = _ref.read(messagePageSizeControllerProvider).rows;
    return (channelWindowCeiling / rows).ceil();
  }

  /// Looks for [messageId] in [channelId], paging older history in while it
  /// is not found. Safe to call again before a previous call has settled: the
  /// older call notices its token has moved on and stops touching [state].
  Future<void> jumpTo(String channelId, String messageId) async {
    final token = ++_token;
    state = MessageJumpSeeking(channelId, messageId, token);
    final store = await _ref.read(storeProvider.future);
    final history = _ref.read(channelHistoryProvider(channelId).notifier);
    final maxPages = _maxPages;
    var fetchFailed = false;

    for (var page = 0; page <= maxPages; page++) {
      if (_token != token) return;
      final depth = await store.transcriptDepthOf(channelId, messageId);
      if (_token != token) return;
      if (depth != null) {
        // Held is not shown: the window must grow to reach a row the store has but the transcript's newest rows do not.
        state = history.widenWindowTo(depth)
            ? MessageJumpArrived(channelId, messageId, token)
            : MessageJumpUnreachable(channelId, messageId, token);
        return;
      }
      if (page == maxPages) break;
      final paged = await _pageOlder(history, store, channelId, token);
      if (paged == _Paged.failed) fetchFailed = true;
      if (paged != _Paged.more) break;
    }
    if (_token != token) return;
    state = fetchFailed
        ? MessageJumpFailed(channelId, messageId, token)
        : MessageJumpUnreachable(channelId, messageId, token);
  }

  /// Pages one step older, and says whether the jump should keep looking.
  Future<_Paged> _pageOlder(
    ChannelHistoryController history,
    MessageStore store,
    String channelId,
    int token,
  ) async {
    // Seeded from the store, not trusted from the screen: a jump can run before any screen has built a frame for this channel.
    history.syncOldest(await store.oldestLocalSeq(channelId));
    // A full window cannot take another page, so looking on would only spin.
    if (history.state.window >= channelWindowCeiling) return _Paged.stop;
    // Retried rather than left failed, or one stale failure wedges every jump at page zero forever.
    if (history.state.failed) {
      await history.retry();
    } else {
      await history.loadOlder();
    }
    if (_token != token) return _Paged.stop;
    if (history.state.failed) return _Paged.failed;
    return history.state.atStart ? _Paged.stop : _Paged.more;
  }

  /// Called once the arrived message has actually been scrolled to and
  /// flashed, so a later rebuild while the flash is still fading does not
  /// repeat either.
  void consume(int token) {
    if (state case MessageJumpArrived(token: final t) when t == token) {
      state = const MessageJumpIdle();
    }
  }

  /// Called once the notice for an unreachable or failed jump has been shown.
  void dismissNotice(int token) {
    final shown = switch (state) {
      MessageJumpUnreachable(token: final t) => t,
      MessageJumpFailed(token: final t) => t,
      _ => null,
    };
    if (shown == token) state = const MessageJumpIdle();
  }

  /// Drops a refusal [channelId] was showing, for a surface that closed without
  /// the person acting on it. A jump still seeking or arrived is left alone.
  void clearNoticeFor(String channelId) {
    if (jumpNoticeFor(state, channelId) != null) {
      state = const MessageJumpIdle();
    }
  }

  /// Drops a jump still in flight or still waiting to be consumed for
  /// [channelId], called when the channel screen showing it is about to stop
  /// being that channel's - otherwise a jump neither finished nor consumed
  /// before the switch would replay against whatever channel is open next.
  void cancelFor(String channelId) {
    final belongsHere = switch (state) {
      MessageJumpIdle() => false,
      MessageJumpSeeking(channelId: final c) => c == channelId,
      MessageJumpArrived(channelId: final c) => c == channelId,
      MessageJumpUnreachable(channelId: final c) => c == channelId,
      MessageJumpFailed(channelId: final c) => c == channelId,
    };
    if (!belongsHere) return;
    // Bumped so a seek still paging stops instead of writing Arrived for a channel nobody is on.
    _token++;
    state = const MessageJumpIdle();
  }
}

final messageJumpProvider =
    StateNotifierProvider<MessageJumpController, MessageJumpState>(
      (ref) => MessageJumpController(ref),
    );

/// The highlight target for [channelId] right now: non-null only while a
/// jump has landed there and is still waiting for the transcript to consume
/// it. A plain function rather than a getter on the state itself, so a
/// caller never has to match the sealed type by hand.
({String messageId, int token})? jumpArrivalFor(
  MessageJumpState state,
  String channelId,
) {
  if (state case MessageJumpArrived(
    channelId: final c,
    :final messageId,
    :final token,
  ) when c == channelId) {
    return (messageId: messageId, token: token);
  }
  return null;
}

/// Whether a jump into [channelId] is still looking for its message.
bool jumpSeekingIn(MessageJumpState state, String channelId) =>
    state is MessageJumpSeeking && state.channelId == channelId;

/// A jump into [channelId] that ended without arriving: what to tell the
/// person, which jump it was, and whether asking again could change anything.
typedef JumpNotice = ({
  String text,
  String messageId,
  int token,
  bool retryable,
});

/// The notice for [state] when it is a refusal in [channelId], else null.
///
/// One place for the sentences, so the search panel and the snack bar a pin or
/// a palette jump falls back on cannot word the same outcome two ways.
JumpNotice? jumpNoticeFor(MessageJumpState state, String channelId) {
  return switch (state) {
    MessageJumpUnreachable(channelId: final c, :final messageId, :final token)
        when c == channelId =>
      (
        text:
            'Could not find that message. It may be deleted or too far back '
            'to load.',
        messageId: messageId,
        token: token,
        retryable: false,
      ),
    MessageJumpFailed(channelId: final c, :final messageId, :final token)
        when c == channelId =>
      (
        text: 'Could not load older messages to find it. Try again.',
        messageId: messageId,
        token: token,
        retryable: true,
      ),
    _ => null,
  };
}
