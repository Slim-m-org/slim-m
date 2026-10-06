// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Marking a conversation unread, from either row menu.
///
/// Shared rather than written twice because the two menus have drifted apart
/// before, and because the order here matters: the server is asked first, and
/// the local row only changes if it agreed. A local-first write would light
/// the dot for a channel the server never marked, and the next refresh would
/// quietly put it out again - a state that flickers is worse than one that
/// waits.
///
/// Takes a [ProviderContainer] rather than a [WidgetRef] for the reason
/// `safety_actions.dart` does: the menu is dismissed before this answers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../providers/providers.dart';

/// Marks [channelId] unread, throwing the [api.ApiException] if the server refuses.
Future<void> markChannelUnread(
  ProviderContainer container,
  String channelId,
) async {
  final read = await container.read(apiProvider).markUnread(channelId);
  final store = await container.read(storeProvider.future);
  await store.setReadMarker(
    channelId,
    read.lastReadSeq,
    manuallyUnread: read.manuallyUnread,
  );
}
