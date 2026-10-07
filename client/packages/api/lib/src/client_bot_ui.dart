// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// The discovery and use halves of bot-contributed UI; a bot registers its own
/// entries from its process. See docs/decisions/0045-bot-contributed-ui.md.
extension SlimmApiBotUi on SlimmApi {
  /// What each bot adds to menus and calls in [channelId].
  Future<List<ChannelBotUi>> listChannelBotUi(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/bot-ui');
    return (json as List<dynamic>)
        .map((b) => ChannelBotUi.fromJson(b as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Uses [entryId] of [botId] on [messageId]. [id] is the caller's own UUID,
  /// so a retry after a timeout is the same use.
  Future<void> useBotMenuEntry({
    required String channelId,
    required String botId,
    required String entryId,
    required String messageId,
    required String id,
  }) =>
      _send(
        'POST',
        '/channels/$channelId/bot-ui/$botId/interactions',
        body: {
          'id': id,
          'surface': 'message_menu',
          'entry_id': entryId,
          'message_id': messageId,
        },
      );

  /// Uses the call control [entryId] of [botId] on the call in [channelId].
  /// [optionId] is the choice made on a control that offers options.
  Future<void> useBotCallControl({
    required String channelId,
    required String botId,
    required String entryId,
    required String id,
    String? optionId,
  }) =>
      _send(
        'POST',
        '/channels/$channelId/bot-ui/$botId/interactions',
        body: {
          'id': id,
          'surface': 'call_control',
          'entry_id': entryId,
          if (optionId != null) 'option_id': optionId,
        },
      );
}
