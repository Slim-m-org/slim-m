// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a stamp shows (decision 0121): an emoji under the key a reaction
/// stores, or a picture by its attachment id. The same on a share and the board.
library;

import 'package:slimm_api/api.dart' as api;

import '../../emoji/providers/emoji_keys.dart';
import '../../emoji/providers/standard_emoji.dart';

sealed class StampContent {
  const StampContent();

  /// The content a relayed stamp frame carries, or null when it carries neither.
  static StampContent? of(api.CanvasScreenAnnotation frame) {
    final attachment = frame.attachment;
    if (attachment != null && attachment.isNotEmpty) {
      return PictureStamp(attachment, animated: frame.animated);
    }
    final emoji = frame.emoji;
    if (emoji != null && emoji.isNotEmpty) return EmojiStamp(emoji);
    return null;
  }

  /// Names the baked picture everywhere it is held: `e:` and the glyph, `c:` and a custom emoji id, or `a:` and an attachment id.
  String imageKey(Map<String, String> customIndex);
}

final class EmojiStamp extends StampContent {
  const EmojiStamp(this.key);

  /// A single emoji, a standard `:shortcode:`, or a custom emoji's id.
  final String key;

  /// The custom emoji this names, or null for a standard one.
  String? customId(Map<String, String> customIndex) =>
      storedCustomEmojiId(key, customIndex);

  /// The character a standard emoji draws as.
  String get glyph => standardEmojiFor(key) ?? key;

  @override
  String imageKey(Map<String, String> customIndex) =>
      switch (customId(customIndex)) {
        final id? => 'c:$id',
        null => 'e:$glyph',
      };

  @override
  bool operator ==(Object other) => other is EmojiStamp && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

final class PictureStamp extends StampContent {
  const PictureStamp(this.attachmentId, {this.animated = false});

  final String attachmentId;

  /// A GIF small enough to animate on a tile, as the server decided.
  final bool animated;

  @override
  String imageKey(Map<String, String> customIndex) => 'a:$attachmentId';

  @override
  bool operator ==(Object other) =>
      other is PictureStamp &&
      other.attachmentId == attachmentId &&
      other.animated == animated;

  @override
  int get hashCode => Object.hash(attachmentId, animated);
}
