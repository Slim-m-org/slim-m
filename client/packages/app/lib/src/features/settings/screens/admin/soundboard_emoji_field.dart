// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A clip's emoji as a form field: what it is now, a way to clear it, and the
/// emoji picker's own button to choose another.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../emoji/providers/emoji_catalog_provider.dart';
import '../../../emoji/widgets/emoji_field_picker.dart';
import '../../../emoji/widgets/stored_emoji.dart';

class SoundClipEmojiField extends ConsumerWidget {
  const SoundClipEmojiField({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  /// A standard emoji or a custom emoji's id; null for none.
  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final index = ref.watch(customEmojiIndexProvider);
    final value = this.value;
    final name = value == null ? null : storedEmojiName(value, index);
    return EmojiFieldPicker(
      semanticLabel: 'Choose an emoji for the clip',
      tooltip: 'Choose emoji',
      onSelect: (token) => onChanged(storableEmoji(token, index)),
      // Inset by the focus ring a text field reserves, so the two boxes line up.
      builder: (context, button) => Container(
        margin: const EdgeInsets.all(focusRingGap + focusRingWidth),
        constraints: const BoxConstraints(minHeight: AppSizes.controlLg),
        padding: const EdgeInsets.only(
          left: AppSpacing.s12,
          right: AppSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: enabled ? tokens.surfaceRaised : tokens.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: tokens.borderStrong),
        ),
        child: Row(
          spacing: AppSpacing.s8,
          children: [
            StoredEmoji(value, placeholder: AppIcons.music),
            Expanded(
              child: Text(
                value == null ? 'No emoji' : name ?? 'Custom emoji',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  color: value == null
                      ? tokens.textSecondary
                      : tokens.textPrimary,
                ),
              ),
            ),
            if (value != null)
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Clear the emoji',
                tooltip: 'Clear',
                onPressed: enabled ? () => onChanged(null) : null,
              ),
            button,
          ],
        ),
      ),
    );
  }
}
