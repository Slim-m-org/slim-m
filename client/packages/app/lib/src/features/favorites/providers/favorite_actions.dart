// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Adding message media to favorites, shared by the image menu, the viewer
/// and the video menu so one failure reads the same wherever it surfaces.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../providers/toasts.dart';
import 'favorites_controller.dart';

/// Favorites [attachment] as seen on [messageId]; null on success, else a sentence for [AppErrorState].
Future<String?> addAttachmentToFavorites(
  WidgetRef ref, {
  required String messageId,
  required api.Attachment attachment,
}) async {
  try {
    await ref
        .read(favoritesProvider.notifier)
        .addAttachment(messageId: messageId, attachmentId: attachment.id);
    ref
        .read(toastsProvider.notifier)
        .show('Added to favorites.', severity: AppToastSeverity.success);
    return null;
  } on api.ApiException catch (e, stack) {
    api.reportFailure(
      api.LogTag.media,
      'favorite ${attachment.filename}',
      e,
      stack,
    );
    return describeApiFailure('favorite ${attachment.filename}', e);
  }
}
