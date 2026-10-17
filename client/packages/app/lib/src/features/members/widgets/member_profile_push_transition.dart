// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card's own push transition between the profile and Moderate, plus the
/// Esc handling both share - split out of `member_profile.dart` to keep that
/// file under the review budget.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart' show AppAction, activatorFor;

/// 180ms push, per the design: the incoming view slides in from the right
/// and fades, rather than the popover growing or shrinking to a second
/// dialog. reduce-motion collapses it to a plain cross-fade. Esc steps back
/// to the profile before it closes the whole card - [onEscape] is called
/// either way and decides which.
class MemberProfilePushTransition extends StatelessWidget {
  const MemberProfilePushTransition({
    super.key,
    required this.child,
    required this.stateKey,
    required this.onEscape,
  });

  final Widget child;

  /// Distinguishes the profile from Moderate for [AnimatedSwitcher], so it
  /// treats a state change as a transition rather than a rebuild.
  final Object stateKey;

  final VoidCallback onEscape;

  @override
  Widget build(BuildContext context) {
    final pushed = AnimatedSwitcher(
      duration: AppMotion.reduced(context, const Duration(milliseconds: 180)),
      switchInCurve: AppMotion.entrance,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.05, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(stateKey), child: child),
    );

    final escape = activatorFor(AppAction.escape);
    return CallbackShortcuts(
      bindings: {if (escape != null) escape: onEscape},
      // Autofocus so Esc has somewhere to bubble from the moment this opens.
      child: Focus(autofocus: true, child: pushed),
    );
  }
}
