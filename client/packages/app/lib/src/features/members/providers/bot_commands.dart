// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bot commands offered in one channel, channel-scoped because visibility
/// is per channel. See docs/decisions/0031-bot-command-registration.md.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

final channelBotCommandsProvider = FutureProvider.autoDispose
    .family<List<api.ChannelBotCommand>, String>(
      (ref, channelId) =>
          ref.watch(apiProvider).listChannelBotCommands(channelId),
    );
