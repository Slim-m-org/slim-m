// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the canvas's drawing tools are folded away, kept on this device.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/preference_controller.dart';

const canvasToolsHiddenKey = 'slimm.canvas.tools_hidden';

class CanvasToolsHidden extends BoolPreferenceController {
  CanvasToolsHidden(super.ref) : super(storageKey: canvasToolsHiddenKey);
}

final canvasToolsHiddenProvider =
    StateNotifierProvider<CanvasToolsHidden, bool>(CanvasToolsHidden.new);
