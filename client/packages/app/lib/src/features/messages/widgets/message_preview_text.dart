// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The preview line under a message list row's author, shared by Pinned,
/// Saved, Threads and the Inbox so the lists cannot drift apart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/mention_names.dart';
import '../providers/message_extras.dart';
import 'reply_target_summary.dart' show previewLine;

/// [previewLine] with this space's mention names. [attachments] are the
/// message's own when the caller has them, else those already fetched for it.
String watchPreviewLine(
  WidgetRef ref, {
  required String messageId,
  required String content,
  List<api.Attachment>? attachments,
}) {
  final held = ref.watch(
    messageExtrasProvider.select(
      (extras) => extras[messageId]?.attachments ?? const <api.Attachment>[],
    ),
  );
  return previewLine(
    content,
    attachments ?? held,
    mentionNames: ref.watch(mentionNamesProvider),
  );
}

class MessagePreviewText extends ConsumerWidget {
  const MessagePreviewText({
    super.key,
    required this.messageId,
    required this.content,
    this.attachments,
  });

  final String messageId;
  final String content;
  final List<api.Attachment>? attachments;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Text(
      watchPreviewLine(
        ref,
        messageId: messageId,
        content: content,
        attachments: attachments,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: tokens.textSecondary),
    );
  }
}
