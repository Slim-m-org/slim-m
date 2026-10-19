// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tap target over a live video that the keyboard can reach: a tab stop,
/// Enter and Space to activate, and a focus ring drawn inside the video.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class FocusableVideoPress extends StatefulWidget {
  const FocusableVideoPress({
    super.key,
    required this.semanticLabel,
    required this.onPressed,
    required this.child,
    this.ringRadius = AppRadii.card,
  });

  final String semanticLabel;
  final VoidCallback onPressed;
  final Widget child;
  final double ringRadius;

  @override
  State<FocusableVideoPress> createState() => _FocusableVideoPressState();
}

class _FocusableVideoPressState extends State<FocusableVideoPress> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.ringRadius),
              border: _focused
                  ? Border.all(color: tokens.focusRing, width: 2)
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
