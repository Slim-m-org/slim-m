// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drops the cached preview and original files of attachments whose message is gone.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, Attachment, LogTag;

import '../../../providers/media_disk_caches.dart';
import '../../../providers/providers.dart';
import 'attachment_preview_bytes.dart';
import 'message_extras.dart';

/// Removes every cached size of each attachment the extras still list for [messageIds].
Future<void> pruneAttachmentCaches(Ref ref, Iterable<String> messageIds) async {
  try {
    final extras = ref.read(messageExtrasProvider);
    final server = ref.read(serverUrlProvider);
    final previews = ref.read(attachmentPreviewCacheProvider);
    final originals = ref.read(attachmentOriginalCacheProvider);
    for (final id in messageIds) {
      for (final attachment
          in extras[id]?.attachments ?? const <Attachment>[]) {
        final key = serverScopedKey(server, attachment.id);
        await previews.removeWithPrefix(key);
        await originals.removeWithPrefix(key);
      }
    }
  } catch (error, stack) {
    // A container that closed first has nothing left to prune through.
    AppLog.swallowed(
      LogTag.media,
      'Could not prune cached attachments',
      error,
      stack,
    );
  }
}
