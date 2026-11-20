// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply's parent that the transcript has not loaded, read from the server
/// by id so an old parent shows instead of reading as gone.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Message;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import 'local_message_of.dart';
import 'message_extras.dart';

/// The channel a reply sits in and the id of the message it answers.
typedef ReplyParentKey = ({String channelId, String messageId});

/// The parent, or null when the server no longer has it for this reader:
/// deleted, or in a channel they cannot see.
///
/// Held in memory for the session, so scrolling back past a reply does not
/// fetch again, and never written to the local store, which keeps the store's
/// history contiguous. A delete or edit that arrives live reads it again, and a failed
/// read is let go, so the next quote to ask tries again.
final replyParentProvider = FutureProvider.autoDispose
    .family<Message?, ReplyParentKey>((ref, key) async {
      final held = ref.keepAlive();
      final changes = ref
          .watch(liveEventsProvider)
          .where(
            (e) => switch (e) {
              api.MessageDeleted(:final messageId) =>
                messageId == key.messageId,
              api.MessageEdited(:final message) => message.id == key.messageId,
              _ => false,
            },
          )
          .listen((_) => ref.invalidateSelf());
      ref.onDispose(changes.cancel);
      try {
        final parent = await ref
            .watch(apiProvider)
            .getMessage(channelId: key.channelId, messageId: key.messageId);
        final extras = ref.read(messageExtrasProvider.notifier)
          ..applyMessages([parent])
          ..pin([parent.id]);
        ref.onDispose(() => extras.unpin([parent.id]));
        return localMessageOf(parent);
      } on api.NotFoundException {
        return null;
      } catch (_) {
        held.close();
        rethrow;
      }
    });
