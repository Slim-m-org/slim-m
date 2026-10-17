// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The way back to the newest message once a reader has scrolled into
/// history, since the read marker only follows the view there and scrolling
/// up should never look like giving up the thread.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Always mounted so its fade has something to reverse against; renders as
/// nothing once the transition settles at [visible] false.
///
/// A small filled circle, not a labelled bar: the affordance only ever means
/// one thing (go to the newest message), so a chevron alone carries it, and
/// a wide pill over a phone transcript would cover more of the content it
/// exists to help reach than it is worth. The visible circle sits at
/// [AppSizes.controlLg] (38); the invisible tap box around it is padded out
/// to [AppSizes.rowTouch] (44) so it never drops under the touch-target
/// floor just because it reads as compact.
class JumpToLatestButton extends StatefulWidget {
  const JumpToLatestButton({
    super.key,
    required this.visible,
    required this.onTap,
  });

  final bool visible;
  final VoidCallback onTap;

  @override
  State<JumpToLatestButton> createState() => _JumpToLatestButtonState();
}

class _JumpToLatestButtonState extends State<JumpToLatestButton> {
  /// Finger-down feedback for a phone, where there is no hover fill to lean
  /// on; a small scale-down that a haptic tick lands alongside.
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AnimatedSwitcher(
      duration: AppMotion.reduced(context, AppMotion.base),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: !widget.visible
          ? const SizedBox.shrink(key: ValueKey('jump-to-latest-hidden'))
          : Padding(
              key: const ValueKey('jump-to-latest-visible'),
              padding: const EdgeInsets.only(bottom: AppSpacing.s12),
              child: Semantics(
                label: 'Jump to latest',
                button: true,
                child: GestureDetector(
                  onTapDown: (_) => setState(() => _pressed = true),
                  onTapUp: (_) => setState(() => _pressed = false),
                  onTapCancel: () => setState(() => _pressed = false),
                  onTap: () {
                    AppHaptics.selection();
                    widget.onTap();
                  },
                  child: SizedBox(
                    key: const Key('jump-to-latest-tap-target'),
                    width: AppSizes.rowTouch,
                    height: AppSizes.rowTouch,
                    child: Center(
                      child: AnimatedScale(
                        scale: _pressed ? AppMotion.pressScale : 1,
                        duration: AppMotion.reduced(context, AppMotion.fast),
                        curve: AppMotion.entrance,
                        child: Container(
                          width: AppSizes.controlLg,
                          height: AppSizes.controlLg,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: tokens.accentSoft,
                            border: Border.all(color: tokens.accentFill),
                          ),
                          child: Icon(
                            AppIcons.chevronDown,
                            size: AppSizes.icon20,
                            color: tokens.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
