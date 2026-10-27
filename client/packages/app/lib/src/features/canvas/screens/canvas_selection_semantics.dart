// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The current selection's own accessibility node - a note's full text,
/// unclipped, reachable by a screen reader with no permission of its own
/// beyond what selecting the object already needed.
///
/// The activity log's 80-character cap on a note's text
/// (`canvas_activity_log.dart`'s own `_noteDetail`) is correct for a log
/// entry and stays; what it never gave a screen-reader user was any path to
/// an object's own content, only a summary of the act that placed it. This
/// closes that for exactly the object select already holds, no more: the
/// select tool's own hit test only ever selects an object this caller
/// authored or holds MANAGE_CANVAS for (`beginSelect`'s `allowed`
/// predicate), so a note nobody has selected, or somebody else's note
/// without MANAGE_CANVAS, is still only ever reachable as an 80-character
/// log summary. That is a real, named gap, not a silent one: reading every
/// note on a shared board needs a different, browsable surface this is not.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class CanvasSelectionSemantics extends StatelessWidget {
  const CanvasSelectionSemantics({
    super.key,
    required this.document,
    this.onOpenActions,
  });

  final CanvasDocument document;

  /// A screen-reader or keyboard route to the selected object's own
  /// bring-to-front/send-to-back/delete menu - the same one a mouse reaches
  /// by right-click, published as `SemanticsAction.longPress` on this node
  /// since it is the one accessibility surface a canvas object already has.
  /// See `canvas_object_context_menu.dart`'s own doc for why this is where
  /// that route hangs rather than a focus node of the menu's own. Null
  /// leaves this node exactly as it always was: an announcement with
  /// nothing to invoke.
  final ValueChanged<String>? onOpenActions;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The document notifies on camera moves too, which move the node with its object.
    listenable: Listenable.merge([document.selectedObjectId, document]),
    builder: (context, _) {
      final selectedId = document.selectedObjectId.value;
      // No node at all with nothing selected - not one with an empty label, which would still be a stop a screen reader's swipe navigation has to pass through for no reason.
      final label = selectedId == null ? null : _labelFor(selectedId);
      final bounds = selectedId == null
          ? null
          : document.objectBounds(selectedId);
      if (label == null || bounds == null) return const SizedBox.shrink();
      final camera = document.camera;
      // Sized to the object on screen: a zero-size node is dropped from the semantics tree.
      return Positioned(
        left: (bounds.x - camera.x) * camera.zoom,
        top: (bounds.y - camera.y) * camera.zoom,
        width: (bounds.w * camera.zoom).clamp(1, double.infinity),
        height: (bounds.h * camera.zoom).clamp(1, double.infinity),
        child: Semantics(
          container: true,
          label: label,
          onLongPress: onOpenActions == null
              ? null
              : () => onOpenActions!(selectedId!),
          child: const SizedBox.expand(),
        ),
      );
    },
  );

  String? _labelFor(String id) {
    final kind = document.kindOf(id);
    if (kind == null) return null;
    return switch (kind) {
      CanvasObjectKind.note =>
        'Selected note: ${document.textOf(id) ?? '(empty)'}',
      CanvasObjectKind.image => 'Selected image',
      CanvasObjectKind.shape => 'Selected shape',
      CanvasObjectKind.text =>
        'Selected text: ${document.textOf(id) ?? '(empty)'}',
      CanvasObjectKind.stroke => 'Selected stroke',
    };
  }
}
