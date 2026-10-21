// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bot commands offered in one channel, channel-scoped because visibility
/// is per channel. See docs/decisions/0031-bot-command-registration.md.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import 'bot_presence_refetch.dart';

final channelBotCommandsProvider = FutureProvider.autoDispose
    .family<List<api.ChannelBotCommand>, String>((ref, channelId) async {
      // A bot going offline or coming back flips its rows, so they refetch.
      final presence = watchBotPresence(ref);
      final commands = await ref
          .watch(apiProvider)
          .listChannelBotCommands(channelId);
      presence.loaded(ref, commands.map((c) => c.botUserId));
      return commands;
    });
