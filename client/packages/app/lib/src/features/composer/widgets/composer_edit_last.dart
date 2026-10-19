// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Up in an empty composer edits the caller's own last message.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../messages/providers/message_actions.dart'
    show lastOwnMessageInChannel;
import '../../messages/providers/message_editing.dart';

/// Opens the caller's own most recent message in [channelId] for inline
/// editing. [isMounted] is checked after each await rather than inside
/// [lastOwnMessageInChannel], which takes no `ref` and so cannot know whether
/// the composer is still around when its snapshot resolves.
///
/// [meProvider] is awaited by its own `.future` rather than read
/// synchronously: nothing else in the composer keeps it warm, so a cold first
/// read would otherwise catch it mid-`AsyncLoading` and find no id at all.
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
