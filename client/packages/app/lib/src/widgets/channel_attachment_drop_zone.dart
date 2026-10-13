// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer/transcript half of drag-and-drop: wraps a whole channel pane
/// so a file dropped anywhere on it - the transcript above the composer
/// included - reaches that channel's own `Composer`, through the exact same
/// `AttachmentStagingController` its attach button and clipboard paste
/// already share.
library;

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/channel_permissions.dart';
import '../providers/composer_attachment_drop.dart';
import 'app_drop_zone.dart';
import 'composer_attachments.dart';

/// Whether a drop should even be offered here.
///
/// A blocked DM never mounts a composer at all (see
/// [ComposerAttachmentDropTarget]'s own doc), and [permissions] mirrors the
/// bits a picked file already needs server-side - a drop must not look like
/// it worked somewhere a pick would already have been refused.
bool canDropAttachments({required int permissions, required bool blockedDm}) =>
    !blockedDm &&
    permissions.hasPermission(Perm.sendMessages) &&
    permissions.hasPermission(Perm.attachFiles);

/// Stages every dropped file through [target], the same staging call a
/// picked or pasted attachment already makes.
///
/// [target] is only null when nothing mounted a composer for this channel at
/// all; [canDropAttachments] is what is meant to have already stopped a drop
/// from reaching here in every case that would otherwise leave it null.
/// Cleared up front, the same precedent the picker's own `_pickAttachment`
/// sets: a retry that succeeds must not leave a stale failure on screen.
Future<void> handleComposerDrop(
  List<DropItem> files,
  ComposerAttachmentDropTarget? target,
) async {
  if (target == null) return;
  target.setError(null);
  for (final file in files) {
    if (file is DropItemDirectory) {
      target.setError("Folders can't be attached - drop a file instead.");
      continue;
    }
    await target.stageFile(
      FileSource(
        name: file.name,
        length: file.length,
        readAll: file.readAsBytes,
        openRead: file.openRead,
      ),
    );
  }
}

class ChannelAttachmentDropZone extends ConsumerWidget {
  const ChannelAttachmentDropZone({
    super.key,
    required this.channelId,
    required this.blockedDm,
    required this.child,
  });

  final String channelId;
  final bool blockedDm;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(myChannelPermissionsProvider(channelId));
    return AppDropZone(
      enabled: canDropAttachments(
        permissions: permissions,
        blockedDm: blockedDm,
      ),
      label: 'Drop to attach',
      icon: AppIcons.attachFile,
      onDrop: (files) => unawaited(
        handleComposerDrop(
          files,
          ref.read(composerAttachmentDropProvider(channelId)),
        ),
      ),
      child: child,
    );
  }
}
