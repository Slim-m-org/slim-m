// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dot a voice channel's chat toggle wears while the chat is closed and holds something unread.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

const voiceChatUnreadKey = Key('voice-chat-unread');
const _dot = 8.0;

/// The small accent dot that says something is waiting.
class VoiceChatUnreadDot extends StatelessWidget {
  const VoiceChatUnreadDot({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return IgnorePointer(
      child: DecoratedBox(
        key: voiceChatUnreadKey,
        decoration: BoxDecoration(
          color: tokens.accent,
          shape: BoxShape.circle,
          border: Border.all(color: tokens.surfaceBase, width: 1.5),
        ),
        child: const SizedBox.square(dimension: _dot),
      ),
    );
  }
}

/// [toggle] with [VoiceChatUnreadDot] over its icon's top corner while [unread].
class VoiceChatToggleDot extends StatelessWidget {
  const VoiceChatToggleDot({
    super.key,
    required this.unread,
    required this.toggle,
    this.touch,
  });

  final bool unread;
  final Widget toggle;

  /// The toggle's own `touch`; null follows [AppTouchTargets.of], as [AppIconButton] does.
  final bool? touch;

  @override
  Widget build(BuildContext context) {
    final touch = this.touch ?? AppTouchTargets.of(context);
    // A touch target pads the same icon wider, so the dot moves in by that much to stay on it.
    final inset =
        AppSpacing.s4 +
        ((touch ? AppSizes.rowTouch : AppSizes.rowPointer) -
                AppSizes.rowPointer) /
            2;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        toggle,
        if (unread)
          Positioned(
            top: inset,
            right: inset,
            child: const VoiceChatUnreadDot(),
          ),
      ],
    );
  }
}
