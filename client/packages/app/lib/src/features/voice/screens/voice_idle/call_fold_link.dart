// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "N more" / "Show all" link under a folded list in the idle voice pane.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The "N more" link: a ghost button's 12 dp of side padding pushed it off the list's left edge.
class CallFoldLink extends StatefulWidget {
  const CallFoldLink({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<CallFoldLink> createState() => _CallFoldLinkState();
}

class _CallFoldLinkState extends State<CallFoldLink> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: widget.label,
      child: InkWell(
        onTap: widget.onPressed,
        focusColor: Colors.transparent,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: touch ? AppSizes.rowTouch : AppSizes.rowPointer,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: Text(
              widget.label,
              style: AppText.ui.copyWith(
                color: tokens.accent,
                fontWeight: AppWeights.medium,
                decoration: _focused ? TextDecoration.underline : null,
                decorationColor: tokens.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
