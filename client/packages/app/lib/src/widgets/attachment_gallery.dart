// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Several images on one message as a compact grid of square tiles, the way
/// Slack shows them, instead of each at full size down the conversation. A
/// tile opens the fullscreen viewer, which pages through every image.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'attachment_view.dart';

/// The most tiles a gallery shows; the last says how many more there are.
const int kGalleryMaxTiles = 4;

/// A message's attachments: its images as one gallery when there are two or
/// more, then everything else (files, videos) one by one as before.
class MessageAttachments extends StatelessWidget {
  const MessageAttachments({super.key, required this.attachments});

  final List<api.Attachment> attachments;

  @override
  Widget build(BuildContext context) {
    final images = openableImages(attachments);
    final gallery = images.length >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (gallery)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: AttachmentGallery(images: images),
          ),
        for (final attachment in attachments)
          if (!gallery || !images.contains(attachment))
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: AttachmentView(attachment: attachment, siblings: images),
            ),
      ],
    );
  }
}

class AttachmentGallery extends StatelessWidget {
  const AttachmentGallery({super.key, required this.images})
    : assert(images.length >= 2);

  final List<api.Attachment> images;

  @override
  Widget build(BuildContext context) {
    final shown = images.take(kGalleryMaxTiles).toList(growable: false);
    // Two or three side by side; four or more as a two by two square.
    final columns = shown.length == 3 ? 3 : 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = AppSpacing.s4;
        // One tile size at any count (half the single-image cap), shrinking only when the column is narrower.
        const fullEdge = (kInlineImageMax - gap) / 2;
        final fitted = (constraints.maxWidth - gap * (columns - 1)) / columns;
        final edge = fitted < fullEdge ? fitted : fullEdge;
        final width = edge * columns + gap * (columns - 1);
        return SizedBox(
          width: width,
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < shown.length; i++)
                AttachmentView(
                  attachment: shown[i],
                  siblings: images,
                  tileEdge: edge,
                  moreCount: i == shown.length - 1
                      ? images.length - shown.length
                      : 0,
                ),
            ],
          ),
        );
      },
    );
  }
}
