// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shell's resting focus, so its shortcuts work with nothing else focused.
///
/// Shortcuts only see keys from a focused descendant. Focus that falls back to
/// a scope above the shell (first-run setup closing, a dialog whose opener is
/// gone, a click on empty space) left Ctrl+K dead until a pointer click landed
/// somewhere focusable; this takes it back whenever that happens, except while
/// the app is inactive (Flutter restores focus itself) or a modal covers it.
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
  ModalRoute<Object?>? _route;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  bool get _appActive {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  bool get _uncovered => _route?.isCurrent ?? true;

  void _reclaim() {
    final primary = FocusManager.instance.primaryFocus;
    final fellAbove =
        primary == null ||
        (primary is FocusScopeNode && _node.ancestors.contains(primary));
    if (!fellAbove || _node.context == null) return;
    if (_appActive && _uncovered) _node.requestFocus();
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: _node, autofocus: true, child: widget.child);
}
