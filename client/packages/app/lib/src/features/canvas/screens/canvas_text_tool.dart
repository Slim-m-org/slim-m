// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text tool's place, long-press and edit wiring, kept out of the pane so the pane only holds glue.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../providers/canvas_text_props.dart';
import '../widgets/canvas_note_editor.dart';
import '../widgets/canvas_text_editor.dart';
import 'canvas_engine.dart';
import 'canvas_forbidden_message.dart';
import 'canvas_ops_controller.dart';
import 'canvas_quick_placement.dart';

class CanvasTextTool {
  CanvasTextTool({
    required this.engine,
    required this.placement,
    required this.ref,
    required this.currentTool,
    required this.changed,
    required this.onPlaced,
    required this.focusBoard,
  });

  CanvasDocument get document => engine.document;
  final CanvasEngine engine;
  final CanvasQuickPlacement Function() placement;
  final WidgetRef ref;
  final CanvasTool Function() currentTool;

  /// Rebuilds the owner after running the given state change.
  final void Function([VoidCallback? mutate]) changed;

  /// Selects a freshly placed box, unless the person moved on while it saved.
  final void Function(String id, CanvasTool startedWith) onPlaced;
  final VoidCallback focusBoard;

  /// Where the editor for a box not placed yet is open, in world coordinates.
  Offset? draft;

  /// Opens the editor for a new box at [world]; nothing is sent until it is saved with text.
  void place(Offset world) {
    if (canvasErrorBlocksDrawing(engine.error)) {
      return;
    }
    changed(() => draft = world);
  }

  /// A finger held on empty canvas opens the same editor the text tool does.
  void longPress(Offset world) {
    if (currentTool() != CanvasTool.pan) return;
    if (hitTestTopmost(document, world, touch: true) != null) return;
    document.selectedObjectId.value = null;
    place(world);
  }

  void cancelDraft() => draft = null;

  /// The editor for the open draft, for the text box [editingId], or the note editor for any other object being edited; null when none is open.
  Widget? editor(
    String? editingId, {
    required VoidCallback onCancel,
    required VoidCallback onEditClosed,
    required void Function(String id, String text) onNoteSave,
  }) {
    if (editingId != null) {
      final box = document.textBoxOf(editingId);
      if (box == null) {
        return CanvasNoteEditor(
          key: ValueKey(editingId),
          document: document,
          objectId: editingId,
          onSave: (text) => onNoteSave(editingId, text),
          onCancel: onCancel,
        );
      }
      return CanvasTextEditor(
        key: ValueKey(editingId),
        document: document,
        objectId: editingId,
        initial: CanvasTextProps(
          text: box.text,
          size: box.size,
          colorKey: box.colorKey,
        ),
        onSave: (props) => unawaited(_saveEdit(editingId, props, onEditClosed)),
        onCancel: onCancel,
      );
    }
    final at = draft;
    if (at == null) return null;
    return CanvasTextEditor(
      key: ValueKey(at),
      document: document,
      anchor: at,
      initial: CanvasTextProps(
        text: '',
        size: ref.read(canvasLastTextStyleProvider).size,
        colorKey: ref.read(canvasLastTextStyleProvider).colorKey,
      ),
      onSave: (props) => unawaited(_saveDraft(at, props)),
      onCancel: onCancel,
    );
  }

  void _remember(CanvasTextProps props) =>
      ref.read(canvasLastTextStyleProvider.notifier).state = (
        size: props.size,
        colorKey: props.colorKey,
      );

  Future<void> _saveDraft(Offset world, CanvasTextProps props) async {
    final startedWith = currentTool();
    changed(() => draft = null);
    _remember(props);
    final placed = await placement().placeText(
      world,
      props,
      onError: engine.reportError,
    );
    if (!ref.context.mounted) return;
    focusBoard();
    if (placed != null) onPlaced(placed.id, startedWith);
  }

  Future<void> _saveEdit(
    String id,
    CanvasTextProps props,
    VoidCallback onEditClosed,
  ) async {
    onEditClosed();
    _remember(props);
    focusBoard();
    await engine.ops.editText(id, props);
    changed();
  }
}
