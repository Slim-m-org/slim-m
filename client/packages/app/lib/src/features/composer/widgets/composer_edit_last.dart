// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Up in an empty composer edits the caller's own last message.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../messages/providers/message_actions.dart'
    show lastOwnMessageInChannel;
import '../../messages/providers/message_editing.dart';

/// Opens the caller's latest message in [channelId] for inline editing; [isMounted] is checked after each await.
/// [meProvider] is awaited via `.future` because nothing keeps it warm and a cold read would see no id.
Future<void> editLastOwnMessage(
  WidgetRef ref,
  String channelId, {
  required bool Function() isMounted,
}) async {
  final store = await ref.read(storeProvider.future);
  if (!isMounted()) return;
  final myId = await ref
      .read(meProvider.future)
      .then<String?>((me) => me.id, onError: (Object _) => null);
  if (!isMounted()) return;
  final message = await lastOwnMessageInChannel(store, channelId, myId);
  if (!isMounted() || message == null) return;
  ref.read(editingMessageIdProvider(channelId).notifier).state = message.id;
}
