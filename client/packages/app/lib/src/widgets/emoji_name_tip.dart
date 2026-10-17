// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small `:name:` label shown over an emoji inside message text, where a
/// [Tooltip] cannot go: the emoji is a run of text, not a widget of its own,
/// so it stays selectable and copies as itself.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Hover rest before the label shows, matching the reaction chip's tooltip.
const Duration emojiNameHoverRest = Duration(milliseconds: 400);

/// How long a long-press label lingers after the finger lifts.
const Duration emojiNameLinger = Duration(milliseconds: 1500);

/// Shows and hides one [EmojiNameTip] in the nearest overlay.
class EmojiNameTipController {
  OverlayEntry? _entry;
  Timer? _timer;

  void showAfterRest(BuildContext context, String name, Offset at) {
    _timer?.cancel();
    _timer = Timer(emojiNameHoverRest, () => show(context, name, at));
  }

  void show(BuildContext context, String name, Offset at) {
    _timer?.cancel();
    hide();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null || !context.mounted) return;
    _entry = OverlayEntry(
      builder: (_) => EmojiNameTip(name: name, at: at),
    );
    overlay.insert(_entry!);
  }

  void hideAfter(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, hide);
  }

  void hide() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
  }

  void dispose() => hide();
}

/// The label itself, centred above [at] (global coordinates).
class EmojiNameTip extends StatelessWidget {
  const EmojiNameTip({super.key, required this.name, required this.at});

  final String name;
  final Offset at;

  static const Key labelKey = Key('emoji_name_tip');

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Positioned(
      left: at.dx,
      top: at.dy - AppSpacing.s8,
      child: IgnorePointer(
        child: FractionalTranslation(
          translation: const Offset(-0.5, -1),
          child: Container(
            key: labelKey,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s8,
              vertical: AppSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: tokens.borderSubtle),
            ),
            child: Text(
              name,
              style: AppText.caption.copyWith(
                color: tokens.textPrimary,
                fontFamily: AppFonts.mono,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
