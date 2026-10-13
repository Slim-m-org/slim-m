// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a channel's drop target (`widgets/channel_attachment_drop_zone.dart`)
/// reaches the one `Composer` mounted for that same channel.
///
/// Keyed by channel id rather than the single global slot
/// `composer_focus.dart` uses for the focus shortcut: a channel pane and its
/// docked thread pane (`thread_screen.dart`) can each have their own
/// `Composer` on screen at once, and a drop has to land in whichever one it
/// was actually dropped over, not whichever mounted last.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/composer_attachments.dart';

/// The staging entry points a drop needs from the composer that owns a
/// channel: the same `stage`/`setError` its own picker and clipboard paste
/// already call, so a drop never invents a second attachment path.
class ComposerAttachmentDropTarget {
  const ComposerAttachmentDropTarget({
    required this.stage,
    required this.stageFile,
    required this.setError,
  });

  final Future<void> Function(Uint8List bytes, String filename) stage;
  final Future<void> Function(FileSource file) stageFile;
  final void Function(String? message) setError;
}

/// Null while no `Composer` is mounted for this channel id (no channel
/// selected, or a blocked DM, which replaces the composer with
/// `BlockedDmNotice` instead of mounting one at all).
final composerAttachmentDropProvider =
    StateProvider.family<ComposerAttachmentDropTarget?, String>(
      (ref, channelId) => null,
    );
