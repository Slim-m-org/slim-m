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
            child: CustomPaint(
              foregroundPainter: _focused
                  ? _OutsetRing(tokens.focusRing)
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

/// The focus ring drawn [focusRingGap] outside the row, so it never touches
/// text that starts at the row's own edge, and without moving the row.
class _OutsetRing extends CustomPainter {
  _OutsetRing(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).inflate(focusRingGap);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        const Radius.circular(AppRadii.control + focusRingGap),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = focusRingWidth
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_OutsetRing old) => old.color != color;
}
