// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where keyboard focus goes when the canvas closes from the call dock.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Set when the canvas was closed from the keyboard, so the control that takes the Close slot's place picks up focus instead of focus falling to the top.
final canvasToggleRefocusProvider = StateProvider<bool>((ref) => false);

/// Asks for that refocus for the frame the close rebuilds in, then withdraws it.
///
/// A flag nobody consumes (a mouse close, where the dock never remounts) would otherwise sit armed and steal focus on some later mount.
void armCanvasToggleRefocus(StateController<bool> refocus) {
  final binding = WidgetsBinding.instance;
  refocus.state = true;
  binding.addPostFrameCallback((_) {
    binding.addPostFrameCallback((_) {
      if (refocus.mounted) refocus.state = false;
    });
    binding.scheduleFrame();
  });
  binding.scheduleFrame();
}
