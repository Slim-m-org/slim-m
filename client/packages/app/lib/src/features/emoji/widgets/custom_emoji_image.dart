// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One of the deployment's own emoji, drawn from its image.
///
/// Square and sized by the caller, because an emoji stands in for a glyph:
/// wherever it appears it has to sit on the same line as the text around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/animation_gate.dart';
import '../providers/emoji_catalog_provider.dart';
import '../../../widgets/image_decode.dart';

export '../providers/emoji_keys.dart' show customEmojiIdFor;

/// While the image is queued or in flight this draws a static tinted tile,
/// the same shape `AttachmentPlaceholder` already uses for a pending
/// attachment - deliberately not an animated spinner. An indeterminate
/// spinner never lets `pumpAndSettle` settle while a cell is still loading,
/// which every screen that renders one of these under a real fetch would
/// then have to work around.
class CustomEmojiImage extends ConsumerWidget {
  const CustomEmojiImage({
    super.key,
    required this.emojiId,
    this.label,
    this.size = 20,
  });

  final String emojiId;

  /// The `:shortcode:` this image stands for, read out in place of the
  /// picture, which no screen reader can describe. Null where an enclosing
  /// [Semantics] already names it, so it is not announced twice.
  final String? label;

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final bytes = ref.watch(customEmojiImageProvider(emojiId));
    // Never decodes past the pixels this tile is ever drawn at.
    final edge = decodeEdge(context, size);
    final image = SizedBox(
      width: size,
      height: size,
      child: switch (bytes) {
        AsyncData(:final value) => AnimationGate(
          child: Image.memory(
            value,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            cacheWidth: edge,
            cacheHeight: edge,
          ),
        ),
        // A fetch that failed says so, distinct from one still queued or in flight below.
        AsyncError() => Icon(
          AppIcons.imageMissing,
          size: size,
          color: tokens.textSecondary,
        ),
        // Queued behind the fetch limiter or already in flight; see the class doc.
        _ => DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.stripe,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      },
    );
    final name = label;
    if (name == null) return image;
    return Semantics(label: name, image: true, child: image);
  }
}
