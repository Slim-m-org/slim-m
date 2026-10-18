// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Marking conversations read from a menu, one row or a whole category or space.
///
/// Takes a [ProviderContainer] for the reason `mark_unread_action.dart` does:
/// the menu is dismissed before the server answers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart';
import '../providers/unread_indicator_rules.dart';

/// Whether [channel] is lit as unread or mentioned on its row.
///
/// Runs the rule the row paints with, so a menu entry is offered exactly when
/// there is a badge to clear: a muted channel with unread messages shows none.
bool channelShowsUnread(
  Channel channel,
  api.NotificationPreference? override, {
  required bool isDm,
}) {
  final indicator = unreadIndicatorFor(
    channelOverride: override,
    isDm: isDm,
    unread: channel.cursor > channel.lastReadSeq,
    mentioned: channel.mentionedSeq > channel.lastReadSeq,
    manuallyUnread: channel.manuallyUnread ?? false,
  );
  return indicator.unread || indicator.mentioned;
}

/// Reads every channel in [channelIds], 200 to a request, throwing the
/// [api.ApiException] if the server refuses.
///
/// The local rows follow the server's answer, never ahead of it, for the
/// reason `markChannelUnread` gives.
Future<void> markChannelsRead(
  ProviderContainer container,
  List<String> channelIds,
) async {
  final api = container.read(apiProvider);
  final store = await container.read(storeProvider.future);
  for (var i = 0; i < channelIds.length; i += _markReadBatch) {
    final batch = channelIds.skip(i).take(_markReadBatch).toList();
    for (final answer in await api.markChannelsRead(batch)) {
      await store.setReadMarker(
        answer.channelId,
        answer.state.lastReadSeq,
        manuallyUnread: answer.state.manuallyUnread,
      );
    }
  }
}

/// The most ids one `POST /read-states/read` accepts.
const _markReadBatch = 200;
