// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The press surface behind the collapsed call strip.
///
/// Sits under the strip's controls rather than around them, so a press on mute,
/// deafen or leave never also reads as "return to the call" and never flashes
/// the pressed fill. It draws the same hover, press and focus states as
/// `AppListRow`, the app's pressable row.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class CallStripPressArea extends StatefulWidget {
  const CallStripPressArea({
    super.key,
    required this.semanticLabel,
    required this.onPressed,
  });

  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  State<CallStripPressArea> createState() => _CallStripPressAreaState();
}

class _CallStripPressAreaState extends State<CallStripPressArea> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _activate() {
    AppHaptics.selection();
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Semantics(
      container: true,
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => _activate(),
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: _activate,
          child: AnimatedContainer(
            duration: AppMotion.reduced(context, AppMotion.fast),
            curve: AppMotion.entrance,
            decoration: BoxDecoration(
              color: _pressed || _hovered
                  ? tokens.surfaceRaised
                  : Colors.transparent,
            ),
            foregroundDecoration: _focused
                ? BoxDecoration(
                    border: Border.all(color: tokens.focusRing, width: 2),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
