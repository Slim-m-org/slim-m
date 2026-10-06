// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What bots add to menus and calls in one channel, and the uses this client
/// has sent and not yet seen answered.
///
/// A use is pending until the bot answers it (`interaction.answered`) and
/// fails visibly if the request is refused or nothing comes back in time. It
/// is in memory only, like a button press. See
/// docs/decisions/0045-bot-contributed-ui.md.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../api_failure.dart';
import '../ids.dart';
import 'live_events.dart';
import 'providers.dart';

/// Channel-scoped because a bot's visibility is per channel.
final channelBotUiProvider = FutureProvider.autoDispose
    .family<List<api.ChannelBotUi>, String>(
      (ref, channelId) => ref.watch(apiProvider).listChannelBotUi(channelId),
    );

/// How long a use waits for the bot before it is shown as failed.
const Duration botUiUseTimeout = Duration(seconds: 5);

/// A menu entry is keyed by the message it was used on, a call control by
/// its call, so each surface shows its own failure in its own place.
String menuUseKey(String messageId, String botId, String entryId) =>
    '${menuUsePrefix(messageId)}$botId|$entryId';

/// What every menu use on [messageId] starts with.
String menuUsePrefix(String messageId) => 'menu|$messageId|';

String controlUseKey(String channelId, String botId, String entryId) =>
    'call|$channelId|$botId|$entryId';

class BotUiUse {
  const BotUiUse({
    required this.id,
    required this.pending,
    required this.retry,
    this.failure,
  });

  final String id;
  final bool pending;

  /// Runs the same use again with a fresh id.
  final Future<void> Function() retry;

  /// Plain words for the person, set only when [pending] is false.
  final String? failure;
}

class BotUiUsesController extends StateNotifier<Map<String, BotUiUse>> {
  BotUiUsesController(this._ref, {Duration timeout = botUiUseTimeout})
    : _timeout = timeout,
      super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event case api.InteractionAnswered(:final interactionId)) {
        _answered(interactionId);
      }
    });
  }

  final Ref _ref;
  final Duration _timeout;
  late final StreamSubscription<api.ServerEvent> _sub;
  final Map<String, Timer> _timers = {};

  Future<void> useMenuEntry({
    required String channelId,
    required String botId,
    required String entryId,
    required String messageId,
  }) => _use(
    menuUseKey(messageId, botId, entryId),
    (id) => _ref
        .read(apiProvider)
        .useBotMenuEntry(
          channelId: channelId,
          botId: botId,
          entryId: entryId,
          messageId: messageId,
          id: id,
        ),
    () => useMenuEntry(
      channelId: channelId,
      botId: botId,
      entryId: entryId,
      messageId: messageId,
    ),
  );

  Future<void> useCallControl({
    required String channelId,
    required String botId,
    required String entryId,
  }) => _use(
    controlUseKey(channelId, botId, entryId),
    (id) => _ref
        .read(apiProvider)
        .useBotCallControl(
          channelId: channelId,
          botId: botId,
          entryId: entryId,
          id: id,
        ),
    () => useCallControl(channelId: channelId, botId: botId, entryId: entryId),
  );

  /// Ignored while the same entry is already pending.
  Future<void> _use(
    String key,
    Future<void> Function(String id) send,
    Future<void> Function() again,
  ) async {
    if (state[key]?.pending ?? false) return;
    final id = newMessageId();
    _put(key, BotUiUse(id: id, pending: true, retry: again));
    _timers[key]?.cancel();
    _timers[key] = Timer(_timeout, () {
      _fail(
        key,
        id,
        'The bot did not answer. It may be offline, so try again in a moment.',
        again,
      );
    });
    try {
      await send(id);
    } on api.ApiException catch (e) {
      _fail(key, id, _describe(e), again);
    }
  }

  String _describe(api.ApiException e) => switch (e) {
    api.NotFoundException() =>
      'That is no longer available. The bot or its message may be gone.',
    api.ForbiddenException() =>
      'You cannot use that here. Controls in a call need you to be on the call.',
    _ => describeApiFailure('use that', e),
  };

  void _answered(String interactionId) {
    for (final entry in state.entries) {
      if (entry.value.id != interactionId) continue;
      _timers.remove(entry.key)?.cancel();
      _remove(entry.key);
      return;
    }
  }

  void _fail(
    String key,
    String id,
    String failure,
    Future<void> Function() again,
  ) {
    final current = state[key];
    if (current == null || current.id != id || !current.pending) return;
    _timers.remove(key)?.cancel();
    _put(key, BotUiUse(id: id, pending: false, failure: failure, retry: again));
  }

  /// Clears a failure the person has read; a pending use stays.
  void dismiss(String key) {
    if (state[key]?.pending ?? false) return;
    _remove(key);
  }

  void _remove(String key) {
    state = {
      for (final entry in state.entries)
        if (entry.key != key) entry.key: entry.value,
    };
  }

  void _put(String key, BotUiUse use) => state = {...state, key: use};

  @override
  void dispose() {
    unawaited(_sub.cancel());
    for (final timer in _timers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}

/// Not `autoDispose`: a use must keep waiting while its screen is off for a
/// moment.
final botUiUsesProvider =
    StateNotifierProvider<BotUiUsesController, Map<String, BotUiUse>>(
      (ref) => BotUiUsesController(ref),
    );
