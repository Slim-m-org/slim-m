// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one tap target the attachment tiles share: pointer, keyboard and
/// screen reader all reach [onTap], and a keyboard focus paints a ring.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class AttachmentTapTarget extends StatefulWidget {
  const AttachmentTapTarget({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<AttachmentTapTarget> createState() => _AttachmentTapTargetState();
}

class _AttachmentTapTargetState extends State<AttachmentTapTarget> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(
              color: _focused ? tokens.focusRing : Colors.transparent,
              width: focusRingWidth,
            ),
          ),
          child: GestureDetector(onTap: widget.onTap, child: widget.child),
        ),
      ),
    );
  }
}
