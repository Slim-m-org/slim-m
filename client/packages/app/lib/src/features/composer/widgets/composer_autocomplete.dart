// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline suggestion list that sits above the composer while a `:`, `@` or
/// `/` trigger is open.
///
/// Above rather than below, always: below is where the send row and, on a
/// phone, the soft keyboard are, and a list that opens under the caret would
/// be covered by the thing you are typing with.
///
/// Presentational only. The composer owns the query, the selection and the
/// keyboard, because it owns the text field those all act on; this draws what
/// it is handed and reports taps.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_autocomplete_items.dart';
import '../../emoji/widgets/custom_emoji_image.dart';
import '../../members/widgets/user_avatar.dart';

/// Room for [maxAutocompleteRows] rows; a longer pick list scrolls.
const double _maxListHeight = AppSizes.controlMd * maxAutocompleteRows;

class ComposerAutocomplete extends StatelessWidget {
  const ComposerAutocomplete({
    super.key,
    required this.suggestions,
    required this.selected,
    required this.onPick,
    required this.onHover,
  });

  final List<AutocompleteSuggestion> suggestions;
  final int selected;
  final void Function(AutocompleteSuggestion) onPick;

  /// Pointer hover moves the selection, so the mouse and the arrow keys are
  /// never both claiming a different row is current.
  final void Function(int) onHover;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: Container(
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.borderStrong),
          borderRadius: BorderRadius.circular(AppRadii.card),
          boxShadow: AppShadows.menu,
        ),
        padding: const EdgeInsets.all(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _maxListHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, suggestion) in suggestions.indexed)
                  _Row(
                    suggestion: suggestion,
                    selected: i == selected,
                    onTap: () => onPick(suggestion),
                    onHover: () => onHover(i),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.suggestion,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final AutocompleteSuggestion suggestion;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  @override
  void initState() {
    super.initState();
    if (widget.selected) _scrollIntoView();
  }

  @override
  void didUpdateWidget(_Row oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) _scrollIntoView();
  }

  void _scrollIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Scrollable.ensureVisible(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final suggestion = widget.suggestion;
    final selected = widget.selected;
    final onTap = widget.onTap;
    final onHover = widget.onHover;
    final tokens = Theme.of(context).extension<AppTokens>()!;

    final Widget leading;
    if (suggestion.imageEmoji != null) {
      leading = CustomEmojiImage(
        emojiId: suggestion.imageEmoji!.id,
        label: suggestion.imageEmoji!.shortcode,
        size: AppSizes.icon16,
      );
    } else if (suggestion.userId != null) {
      leading = UserAvatar(
        userId: suggestion.userId!,
        name: suggestion.label,
        size: AppAvatarSize.s16,
      );
    } else if (suggestion.glyph != null) {
      leading = Text(
        suggestion.glyph!,
        // Matches the icon fallback below's own size, so the leading slot reads level.
        style: const TextStyle(fontSize: AppSizes.icon16, height: 1.1),
      );
    } else {
      final IconData icon;
      if (suggestion.isMassMention) {
        icon = AppIcons.members;
      } else if (suggestion.isRoleMention) {
        icon = AppIcons.shield;
      } else {
        icon = AppIcons.code;
      }
      leading = Icon(icon, size: AppSizes.icon16, color: tokens.textSecondary);
    }

    return Semantics(
      label: suggestion.label,
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: AppSizes.controlMd,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              // A fill, not a ring: focus never leaves the text field.
              color: selected ? tokens.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Row(
              children: [
                SizedBox(width: 20, child: Center(child: leading)),
                const SizedBox(width: AppSpacing.s8),
                Flexible(
                  child: Text(
                    suggestion.label,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui.copyWith(color: tokens.textPrimary),
                  ),
                ),
                if (suggestion.detail != null) ...[
                  const SizedBox(width: AppSpacing.s8),
                  Flexible(
                    child: Text(
                      suggestion.detail!,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: AppText.code.copyWith(
                        fontSize: 11,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
