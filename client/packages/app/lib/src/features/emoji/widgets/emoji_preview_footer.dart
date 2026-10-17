// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Discord's own preview strip under its picker: whichever emoji is under
/// the pointer, held by a finger, or - lacking either - sits at the
/// keyboard's own highlight, so it is never a pointer-only affordance (see
/// desktop-vs-mobile.md's rule 1). `composer_emoji_browse.dart` decides
/// which of those three wins and hands the result here.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'custom_emoji_image.dart';
import 'emoji_catalog.dart';

class EmojiPreviewFooter extends StatelessWidget {
  const EmojiPreviewFooter({super.key, required this.emoji});

  /// Null before anything has been hovered, pressed or highlighted yet -
  /// blank rather than absent, so the footer's own height never makes the
  /// grid above it jump once something is.
  final PickerEmoji? emoji;

  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final entry = emoji;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
        child: Row(
          children: [
            SizedBox(
              width: AppSizes.icon24,
              height: AppSizes.icon24,
              child: switch (entry) {
                null => null,
                UnicodeEmoji(:final emoji) => Center(
                  child: Text(
                    emoji.char,
                    style: const TextStyle(fontSize: 20, height: 1),
                  ),
                ),
                DeploymentEmoji(:final emoji) => CustomEmojiImage(
                  emojiId: emoji.id,
                ),
              },
            ),
            const SizedBox(width: AppSpacing.s8),
            Expanded(
              child: entry == null
                  ? const SizedBox.shrink()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: tokens.textPrimary,
                          ),
                        ),
                        Text(
                          entry.shortcode,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.micro.copyWith(
                            color: tokens.textSecondary,
                            fontFamily: AppFonts.mono,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
