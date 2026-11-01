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

/// The emoji id a `:shortcode:` names, or null when [token] names none of the
/// deployment's own. [index] is `customEmojiIndexProvider`'s name-to-id map.
///
/// The one place that reads the colon delimiters back off a token, so a
/// message body and a reaction chip cannot drift apart about what resolves.
/// A miss is the normal case (most colon runs name nothing) and returns null
/// rather than throwing, which leaves the caller showing the text it had. It
/// judges the token alone: whether the text around one reads as an emoji at
/// all is the caller's, since only a message body has text around it.
String? customEmojiIdFor(String token, Map<String, String> index) {
  if (token.length < 3 || !token.startsWith(':') || !token.endsWith(':')) {
    return null;
  }
  return index[token.substring(1, token.length - 1).toLowerCase()];
}

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
