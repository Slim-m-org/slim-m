// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A rail footer row's way back to something live elsewhere (a call, a voice
/// message still recording): a tap, Enter or Space, with the focus ring.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class RailFooterPressTarget extends StatefulWidget {
  const RailFooterPressTarget({
    super.key,
    required this.tooltip,
    required this.semanticLabel,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final String semanticLabel;
  final VoidCallback onPressed;
  final Widget child;

  @override
  State<RailFooterPressTarget> createState() => _RailFooterPressTargetState();
}

class _RailFooterPressTargetState extends State<RailFooterPressTarget> {
  bool _pressed = false;
  bool _focused = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  void _activate() {
    AppHaptics.selection();
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Tooltip(
      message: widget.tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: widget.semanticLabel,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => _activate(),
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _press(true),
            onTapUp: (_) => _press(false),
            onTapCancel: () => _press(false),
            onTap: _activate,
            child: Container(
              foregroundDecoration: _focused
                  ? BoxDecoration(
                      border: Border.all(color: tokens.focusRing, width: 2),
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    )
                  : null,
              child: AnimatedOpacity(
                opacity: _pressed ? 0.6 : 1,
                duration: AppMotion.reduced(context, AppMotion.fast),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
