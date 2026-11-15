// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When the composer may send, and when the mic takes Send's place.
library;

import 'composer_attachments.dart';
import 'composer_text_stats.dart';

class ComposerSendGate {
  const ComposerSendGate({
    required this.commandRunning,
    required this.stats,
    required this.attachments,
    required this.slowModeRemaining,
  });

  /// True while a command awaits its result, so a second send cannot rerun it.
  final bool commandRunning;
  final ComposerTextStats stats;
  final AttachmentStagingController attachments;

  /// Seconds before slow mode allows another send.
  final int slowModeRemaining;

  /// A staged file is sendable on its own: a photo needs no caption, and the
  /// server accepts an empty body precisely when attachments ride along.
  /// Blocked while anything staged is still uploading or has failed, or a
  /// send would go out missing whatever has not resolved to an id yet.
  /// Also blocked over the character limit, so a doomed request never
  /// reaches the wire at all; see [ComposerBanners]'s `overLimitBy` band for
  /// where that refusal is explained.
  bool get canSend =>
      !commandRunning &&
      (stats.hasSendableText || !attachments.isEmpty) &&
      !attachments.hasBlockingAttachment &&
      stats.overBy == null &&
      slowModeRemaining <= 0;

  /// The mic stands in for Send only while there is nothing to send and nothing pending.
  bool get canRecord =>
      !commandRunning &&
      !stats.hasText &&
      attachments.isEmpty &&
      slowModeRemaining <= 0;
}
