// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The composer's discovery half of bot command registration; registering
/// has no binding here since only a bot's own process calls it. See
/// docs/decisions/0031-bot-command-registration.md.
extension SlimmApiBotCommands on SlimmApi {
  /// Bot commands the caller may currently be offered in [channelId].
  Future<List<ChannelBotCommand>> listChannelBotCommands(
    String channelId,
  ) async {
    final json = await send('GET', '/channels/$channelId/bot-commands');
    return (json as List<dynamic>)
        .map((c) => ChannelBotCommand.fromJson(c as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// A bot's own whole registration, for its profile section.
  Future<BotCommandRegistration> getBotCommands(String botId) async {
    final json = await send('GET', '/bots/$botId/commands');
    return BotCommandRegistration.fromJson(json as Map<String, dynamic>);
  }
}
