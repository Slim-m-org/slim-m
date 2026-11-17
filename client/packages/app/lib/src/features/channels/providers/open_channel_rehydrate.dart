// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Refetching what the open channels show, for frames that are never replayed:
/// a voice message's transcript, a reaction tally, a bot's buttons. Reading
/// the message is their catch-up, and nothing else rereads a channel that
/// stays open.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../../../providers/server_info.dart';
import '../../messages/providers/message_search.dart' show ProviderReader;
import 'channel_history.dart';
import 'mounted_channels.dart';

/// Refetches each open channel's newest page; run once a reconnect is live.
void rehydrateOpenChannels(ProviderReader read) {
  for (final id in read(mountedChannelsProvider).openChannelIds) {
    unawaited(read(channelHistoryProvider(id).notifier).hydrate());
  }
}

/// [rehydrateOpenChannels] once `/version` says the Space transcribes voice
/// messages again: messages read while it was off carry no transcript.
Future<void> rehydrateIfTranscriptsTurnedOn(Ref ref) async {
  final wasOff =
      ref.read(serverInfoProvider).valueOrNull?.transcribeVoiceMessages ==
      false;
  ref.invalidate(serverInfoProvider);
  if (!wasOff) return;
  final sub = ref.listen(serverInfoProvider.future, (_, _) {});
  try {
    final info = await sub.read();
    if (info.transcribeVoiceMessages) rehydrateOpenChannels(ref.read);
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.sync,
      'Could not reread Space settings; the next reconnect rereads channels',
      error,
      stack,
    );
  } finally {
    sub.close();
  }
}
