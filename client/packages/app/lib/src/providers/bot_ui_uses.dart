// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What bots add to menus and calls in one channel, and the uses this client
/// has sent and not yet seen answered.
///
/// A use is pending until the bot answers it (`interaction.answered`) and
/// fails visibly if the request is refused or nothing comes back in time. It
/// is in memory only, like a button press. See
/// docs/decisions/0045-bot-contributed-ui.md.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../api_failure.dart';
import 'pending_interactions.dart';
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
    'menu|$messageId|$botId|$entryId';

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

class BotUiUsesController extends PendingInteractions<BotUiUse> {
  BotUiUsesController(this._ref, {Duration timeout = botUiUseTimeout})
    : super(_ref, timeout);

  final Ref _ref;

  @override
  String idOf(BotUiUse value) => value.id;

  @override
  bool isPending(BotUiUse value) => value.pending;

  @override
  BotUiUse failed(BotUiUse current, String failure) => BotUiUse(
    id: current.id,
    pending: false,
    failure: failure,
    retry: current.retry,
  );

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

  Future<void> _use(
    String key,
    Future<void> Function(String id) send,
    Future<void> Function() again,
  ) => start(
    key,
    pending: (id) => BotUiUse(id: id, pending: true, retry: again),
    send: send,
    describe: _describe,
  );

  String _describe(api.ApiException e) => switch (e) {
    api.NotFoundException() =>
      'That is no longer available. The bot or its message may be gone.',
    api.ForbiddenException() =>
      'You cannot use that here. Controls in a call need you to be on the call.',
    _ => describeApiFailure('use that', e),
  };

  void dismiss(String key) => dismissKey(key);
}

/// Not `autoDispose`: a use must keep waiting while its screen is off for a
/// moment.
final botUiUsesProvider =
    StateNotifierProvider<BotUiUsesController, Map<String, BotUiUse>>(
      (ref) => BotUiUsesController(ref),
    );
