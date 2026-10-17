// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's one canvas button: opens the canvas, and closes it from the
/// same slot once it is open (decision 0047 point 4).
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../voice/screens/call_dock_button.dart';

class CanvasDockToggle extends StatelessWidget {
  const CanvasDockToggle({
    super.key,
    required this.open,
    required this.onPressed,
  });

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CallDockButton(
    icon: AppIcons.canvas,
    tooltip: open ? 'Close canvas' : 'Open canvas',
    active: open,
    onPressed: onPressed,
  );
}
