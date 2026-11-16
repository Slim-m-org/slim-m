// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An emoji as a soundboard clip stores it: one standard emoji or a custom
/// emoji's id, the same encoding a reaction takes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/emoji_catalog_provider.dart';
import 'custom_emoji_image.dart';
import 'emoji_names.dart';
import 'standard_emoji.dart';

final _emojiId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// The custom emoji [value] names, by id or `:shortcode:`, or null for a
/// standard one. [index] is `customEmojiIndexProvider`'s name-to-id map.
///
/// An id the catalog has not loaded yet still counts, so it draws as an image.
String? storedCustomEmojiId(String value, Map<String, String> index) {
  if (_emojiId.hasMatch(value) || index.containsValue(value)) return value;
  return customEmojiIdFor(value, index);
}

/// What the emoji picker hands back, as it is stored: a custom emoji's
/// `:shortcode:` becomes its id.
String storableEmoji(String token, Map<String, String> index) =>
    customEmojiIdFor(token, index) ?? token;

/// The `:name:` [value] goes by, or null when the catalog does not know it.
String? storedEmojiName(String value, Map<String, String> index) {
  final id = storedCustomEmojiId(value, index);
  if (id == null) {
    return standardEmojiShortcode(standardEmojiFor(value) ?? value);
  }
  for (final MapEntry(:key, value: entry) in index.entries) {
    if (entry == id) return ':$key:';
  }
  return null;
}

/// [value] drawn [size] square, or the [placeholder] icon when it is null.
class StoredEmoji extends ConsumerWidget {
  const StoredEmoji(
    this.value, {
    super.key,
    required this.placeholder,
    this.size = AppSizes.icon20,
  });

  final String? value;

  /// Drawn in the emoji's place when there is none; an icon, never an emoji.
  final IconData placeholder;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = this.value;
    if (value == null) {
      final tokens = Theme.of(context).extension<AppTokens>()!;
      return Icon(placeholder, size: size, color: tokens.textSecondary);
    }
    final id = storedCustomEmojiId(value, ref.watch(customEmojiIndexProvider));
    if (id != null) return CustomEmojiImage(emojiId: id, size: size);
    return SizedBox.square(
      dimension: size,
      // A colour glyph is a little wider than its font size; it overhangs both sides evenly.
      child: OverflowBox(
        maxWidth: double.infinity,
        child: Text(
          standardEmojiFor(value) ?? value,
          maxLines: 1,
          softWrap: false,
          // Sized like the icon it stands beside, which text scaling never grows either.
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            // The emoji face first: IBM Plex has its own plain glyph for a few, such as the cross mark.
            fontFamily: AppFonts.emoji.first,
            fontFamilyFallback: AppFonts.emoji,
            fontSize: size,
            height: 1,
          ),
        ),
      ),
    );
  }
}
