// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shell's resting focus, so its shortcuts work with nothing else focused.
///
/// Shortcuts only see keys from a focused descendant. Focus that falls back to
/// a scope above the shell (first-run setup closing, a dialog whose opener is
/// gone, a click on empty space) left Ctrl+K dead until a pointer click landed
/// somewhere focusable; this takes it back whenever that happens.
library;

import 'package:flutter/widgets.dart';

class ShellFocusAnchor extends StatefulWidget {
  const ShellFocusAnchor({required this.child, super.key});

  final Widget child;

  @override
  State<ShellFocusAnchor> createState() => _ShellFocusAnchorState();
}

class _ShellFocusAnchorState extends State<ShellFocusAnchor> {
  final _node = FocusNode(debugLabel: 'shell', skipTraversal: true);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_reclaim);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_reclaim);
    _node.dispose();
    super.dispose();
  }

  void _reclaim() {
    final primary = FocusManager.instance.primaryFocus;
    final fellAbove =
        primary == null ||
        (primary is FocusScopeNode && _node.ancestors.contains(primary));
    if (fellAbove && _node.context != null) _node.requestFocus();
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: _node, autofocus: true, child: widget.child);
}
