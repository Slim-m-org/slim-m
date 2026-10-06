// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a reply names when its target has no text: the attachment's kind as a
/// short label, and a thumbnail or glyph to go with it. Shared by the staged
/// banner above the composer and the quote above a sent reply, so a photo
/// reads as a photo in both.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/attachment_bytes.dart';
import '../providers/media_preferences.dart';
import '../message_preview.dart';
import 'attachment_view.dart' show isInlineImage, isVideo;
import 'image_decode.dart';

/// The label for a text-less target, or empty when it carried nothing.
String attachmentKindLabel(List<api.Attachment> attachments) {
  if (attachments.isEmpty) return '';
  if (attachments.length > 1) return '${attachments.length} attachments';
  final only = attachments.single;
  if (only.contentType.startsWith('image/')) return 'Photo';
  if (isVideo(only.contentType)) return 'Video';
  if (only.contentType.startsWith('audio/')) return 'Voice message';
  return only.filename;
}

/// One line naming a message: its text flattened, else what it attached, else
/// "(no text)". Shared by every list that previews a message, so none can
/// print raw markup or leave a photo-only message blank.
String previewLine(String content, List<api.Attachment> attachments) {
  final text = plainPreview(content);
  if (text.isNotEmpty) return text;
  final kind = attachmentKindLabel(attachments);
  return kind.isEmpty ? '(no text)' : kind;
}

IconData _glyphFor(List<api.Attachment> attachments) {
  if (attachments.length != 1) return AppIcons.attachFile;
  final type = attachments.single.contentType;
  if (type.startsWith('image/')) return AppIcons.image;
  if (isVideo(type)) return AppIcons.camera;
  if (type.startsWith('audio/')) return AppIcons.mic;
  return AppIcons.attachFile;
}

/// A small rounded thumbnail of a text-less reply target.
///
/// Stays a glyph, never a fetch, for anything the transcript would not decode
/// inline and for a reader who turned off auto-download.
class ReplyAttachmentThumb extends ConsumerWidget {
  const ReplyAttachmentThumb({
    super.key,
    required this.attachments,
    required this.edge,
  });

  final List<api.Attachment> attachments;
  final double edge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    Widget frame(Widget child) => ClipRRect(
      key: const ValueKey('reply-attachment-thumb'),
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: SizedBox(
        width: edge,
        height: edge,
        child: ColoredBox(color: tokens.surfaceRaised, child: child),
      ),
    );
    Widget glyph(IconData icon) => Center(
      child: Icon(icon, size: edge / 2, color: tokens.textSecondary),
    );

    final fallback = _glyphFor(attachments);
    final sole = attachments.length == 1 ? attachments.single : null;
    if (sole == null || !isInlineImage(sole.contentType)) {
      return frame(glyph(fallback));
    }
    if (ref.watch(mediaAutoDownloadControllerProvider) ==
        MediaAutoDownload.manual) {
      return frame(glyph(fallback));
    }
    return frame(
      ref
          .watch(attachmentBytesProvider(sole.id))
          .when(
            data: (bytes) => Image.memory(
              bytes,
              fit: BoxFit.cover,
              cacheWidth: decodeEdge(context, edge),
              cacheHeight: decodeEdge(context, edge),
              errorBuilder: (_, _, _) => glyph(fallback),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => glyph(fallback),
          ),
    );
  }
}
