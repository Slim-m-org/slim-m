// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a scoped clear removes, and the seam the overflow menu reaches it through.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// The object kinds a wire scope names; empty means every kind.
Set<CanvasObjectKind> canvasKindsOf(api.CanvasClearScope scope) => {
  for (final kind in CanvasObjectKind.values)
    if (scope.kinds.contains(kind.name)) kind,
};

/// A kind-based clear the sheet offers.
enum CanvasClearTarget {
  drawings('Drawings', ['stroke']),
  images('Images', ['image']),
  notesAndShapes('Notes and shapes', ['note', 'shape']);

  const CanvasClearTarget(this.label, this.kinds);

  final String label;
  final List<String> kinds;

  api.CanvasClearScope get scope => api.CanvasClearScope(kinds: kinds);
}

/// A scoped clear picked in the sheet, with the words the confirm dialog uses.
class CanvasClearChoice {
  const CanvasClearChoice(this.scope, this.subject);

  final api.CanvasClearScope scope;

  /// What goes, as a noun phrase: "all drawings", "Ann's content".
  final String subject;
}

/// The scoped half of the clear control: the clear itself and who has content to clear.
class CanvasScopedClear {
  const CanvasScopedClear({required this.clear, required this.authorIds});

  final Future<void> Function(api.CanvasClearScope scope) clear;
  final Set<String> Function() authorIds;
}
