// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finishes a share once its conversation is on screen: the composer there
/// stages the shared files exactly as it would a dropped one, so an oversize
/// file is refused inline in that composer. Nothing is sent.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../composer/providers/composer_attachment_drop.dart';
import '../providers/incoming_share.dart';
import 'shared_file_source.dart';

/// The server accepts this many attachments per message
/// (`MAX_ATTACHMENTS_PER_MESSAGE` in `store/attachments.rs`).
const kMaxSharedFiles = 10;

/// Said when the other app shared more than the OS let slim-m read.
String unreadableNotice(int count) => count == 1
    ? 'One shared item could not be read, so it is left out.'
    : '$count shared items could not be read, so they are left out.';

/// Stages [share]'s files through [target]. A refusal from the staging itself
/// (a file over the server's limit) replaces the notes set up front.
Future<void> stageShare(
  ComposerAttachmentDropTarget target,
  IncomingShare share,
) async {
  final files = share.files;
  if (files.length > kMaxSharedFiles) {
    target.setError(
      'Only the first $kMaxSharedFiles files fit in one message.',
    );
  } else if (share.unreadable > 0) {
    target.setError(unreadableNotice(share.unreadable));
  } else {
    target.setError(null);
  }
  for (final file in files.take(kMaxSharedFiles)) {
    await target.stageFile(sharedFileSource(file));
  }
}

/// Wraps a conversation so a share handed to [channelId] is staged into its
/// composer the moment that composer mounts.
class ChannelShareHandoff extends ConsumerStatefulWidget {
  const ChannelShareHandoff({
    super.key,
    required this.channelId,
    required this.child,
  });

  final String channelId;
  final Widget child;

  @override
  ConsumerState<ChannelShareHandoff> createState() =>
      _ChannelShareHandoffState();
}

class _ChannelShareHandoffState extends ConsumerState<ChannelShareHandoff> {
  @override
  void initState() {
    super.initState();
    // The composer may have registered before this wrapper first listened.
    WidgetsBinding.instance.addPostFrameCallback((_) => _stageIfReady());
  }

  void _stageIfReady() {
    if (!mounted) return;
    final handoff = ref.read(shareHandoffProvider);
    final target = ref.read(composerAttachmentDropProvider(widget.channelId));
    if (handoff == null || handoff.channelId != widget.channelId) return;
    if (target == null) return;
    ref.read(shareHandoffProvider.notifier).state = null;
    unawaited(stageShare(target, handoff.share));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      composerAttachmentDropProvider(widget.channelId),
      (_, _) => _stageIfReady(),
    );
    ref.listen(shareHandoffProvider, (_, _) => _stageIfReady());
    return widget.child;
  }
}
