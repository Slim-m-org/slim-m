// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's one canvas button: opens the canvas, and closes it from the
/// same slot once it is open (decision 0047 point 4).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../voice/widgets/call_dock_button.dart';

/// Set when the canvas was closed from the keyboard, so the toggle that takes
/// the Close slot's place picks up focus instead of focus falling to the top.
final canvasToggleRefocusProvider = StateProvider<bool>((ref) => false);

class CanvasDockToggle extends ConsumerStatefulWidget {
  const CanvasDockToggle({
    super.key,
    required this.open,
    required this.onPressed,
  });

  final bool open;
  final VoidCallback onPressed;

  @override
  ConsumerState<CanvasDockToggle> createState() => _CanvasDockToggleState();
}

class _CanvasDockToggleState extends ConsumerState<CanvasDockToggle> {
  final _scope = FocusNode(skipTraversal: true, debugLabel: 'canvas toggle');

  @override
  void initState() {
    super.initState();
    if (!widget.open) _takeFocusIfAsked();
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  void _takeFocusIfAsked() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(canvasToggleRefocusProvider)) return;
      ref.read(canvasToggleRefocusProvider.notifier).state = false;
      final button = _scope.descendants.where((n) => n.canRequestFocus);
      if (button.isNotEmpty) button.first.requestFocus();
    });
  }

  void _press() {
    if (widget.open && _scope.hasFocus) {
      ref.read(canvasToggleRefocusProvider.notifier).state = true;
    }
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _scope,
    canRequestFocus: false,
    child: CallDockButton(
      icon: AppIcons.canvas,
      tooltip: widget.open ? 'Close canvas' : 'Open canvas',
      active: widget.open,
      onPressed: _press,
    ),
  );
}

/// The way back out of fullscreen, in the slot the close button holds otherwise.
class CanvasDockExitFullscreen extends StatelessWidget {
  const CanvasDockExitFullscreen({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CallDockButton(
    icon: AppIcons.expand,
    tooltip: 'Exit fullscreen',
    // The glyph entering fullscreen carries, lit: there is no shrink glyph in the dock's set.
    active: true,
    onPressed: onPressed,
  );
}
