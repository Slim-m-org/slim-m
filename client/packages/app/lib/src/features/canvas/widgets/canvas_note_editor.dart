// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A placed note edited where it sits: a raised field over the note's own box
/// that follows the camera, with the composer's input features.
///
/// Escape or Cancel keeps the old text; Save, Ctrl or Cmd plus Enter, or a
/// click outside commits. Editing down to nothing cancels, since this field
/// has no way to delete the note.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_note_field.dart';

/// The narrowest the editor gets, so a small note still has room to type.
const double canvasNoteEditorMinWidth = 280;

class CanvasNoteEditor extends StatefulWidget {
  const CanvasNoteEditor({
    super.key,
    required this.document,
    required this.objectId,
    required this.onSave,
    required this.onCancel,
  });

  final CanvasDocument document;
  final String objectId;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  @override
  State<CanvasNoteEditor> createState() => _CanvasNoteEditorState();
}

class _CanvasNoteEditorState extends State<CanvasNoteEditor> {
  late final _initial = widget.document.noteTextOf(widget.objectId) ?? '';
  late final _controller = TextEditingController(text: _initial)
    ..selection = TextSelection.collapsed(offset: _initial.length);
  final _focus = FocusNode();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Asked for, not autofocus alone: the pane's own shortcut focus can still hold it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (_done) return;
    _done = true;
    final text = _controller.text.trim();
    if (text.isEmpty || text == _initial) {
      widget.onCancel();
    } else {
      widget.onSave(text);
    }
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _save,
          ),
        ),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: widget.document,
            builder: (context, _) {
              final bounds = widget.document.objectBounds(widget.objectId);
              if (bounds == null) {
                // The note was removed under the editor.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _cancel();
                });
                return const SizedBox.shrink();
              }
              final camera = widget.document.camera;
              return CustomSingleChildLayout(
                delegate: _EditorLayout(
                  anchor: Offset(
                    (bounds.x - camera.x) * camera.zoom,
                    (bounds.y - camera.y) * camera.zoom,
                  ),
                  noteWidth: bounds.w * camera.zoom,
                  keyboardInset: inset,
                ),
                child: _Panel(
                  controller: _controller,
                  focusNode: _focus,
                  onSave: _save,
                  onCancel: _cancel,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.controller,
    required this.focusNode,
    required this.onSave,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s8),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.accentFill),
          borderRadius: BorderRadius.circular(AppRadii.card),
          boxShadow: AppShadows.menu,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CanvasNoteField(
              controller: controller,
              focusNode: focusNode,
              onSave: onSave,
              onCancel: onCancel,
              minLines: 2,
              maxLines: 8,
            ),
            const SizedBox(height: AppSpacing.s4),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: AppSpacing.s8,
                children: [
                  AppButton(
                    label: 'Cancel',
                    variant: AppButtonVariant.ghost,
                    size: AppButtonSize.sm,
                    onPressed: onCancel,
                  ),
                  AppButton(
                    label: 'Save',
                    variant: AppButtonVariant.primary,
                    size: AppButtonSize.sm,
                    onPressed: onSave,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Puts the panel over the note's top left, slid back into view when the note
/// is near an edge or the keyboard covers its natural spot.
class _EditorLayout extends SingleChildLayoutDelegate {
  const _EditorLayout({
    required this.anchor,
    required this.noteWidth,
    required this.keyboardInset,
  });

  static const double _margin = AppSpacing.s8;

  final Offset anchor;
  final double noteWidth;
  final double keyboardInset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final room = constraints.maxWidth - _margin * 2;
    final width = noteWidth.clamp(canvasNoteEditorMinWidth, room).toDouble();
    return BoxConstraints(
      minWidth: width.clamp(0, room).toDouble(),
      maxWidth: width.clamp(0, room).toDouble(),
      maxHeight: (constraints.maxHeight - keyboardInset - _margin * 2)
          .clamp(0, double.infinity)
          .toDouble(),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = size.width - childSize.width - _margin;
    final maxY = size.height - keyboardInset - childSize.height - _margin;
    return Offset(
      anchor.dx.clamp(_margin, maxX < _margin ? _margin : maxX).toDouble(),
      anchor.dy.clamp(_margin, maxY < _margin ? _margin : maxY).toDouble(),
    );
  }

  @override
  bool shouldRelayout(_EditorLayout old) =>
      old.anchor != anchor ||
      old.noteWidth != noteWidth ||
      old.keyboardInset != keyboardInset;
}
