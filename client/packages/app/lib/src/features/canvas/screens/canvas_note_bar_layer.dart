// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The style bar over the selected note, and over a note being typed in.
///
/// It shows for a note this person may edit, while the Move tool is armed and the note is not being dragged.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart'
    show AppSizes, AppSpacing;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../providers/dock_reservation.dart';
import '../../../widgets/text_insert.dart';
import '../../emoji/widgets/emoji_field_picker.dart';
import '../widgets/canvas_note_editor.dart';
import '../widgets/canvas_note_style_options.dart';
import '../widgets/canvas_selection_bar.dart';

class CanvasNoteBarLayer extends StatelessWidget {
  const CanvasNoteBarLayer({
    super.key,
    required this.document,
    required this.tool,
    required this.session,
    required this.mayEdit,
    required this.onStyle,
    this.focus,
  });

  final CanvasDocument document;
  final CanvasTool tool;

  /// The note being typed in, whose text the bar's emoji button inserts into.
  final CanvasNoteEditSession? session;

  /// Whether this person may restyle the note: its author or a canvas manager, and it is not locked.
  final bool Function(String id) mayEdit;
  final void Function(String id, CanvasNoteStyle style) onStyle;

  /// Lets the object menu's Style item put the keyboard on the bar.
  final FocusNode? focus;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        document,
        document.selectedObjectId,
        document.elevatedObjectId,
      ]),
      builder: (context, _) {
        final id = session?.objectId ?? document.selectedObjectId.value;
        final bounds = id == null ? null : document.objectBounds(id);
        final style = id == null ? null : document.noteStyleOf(id);
        final dragging = document.elevatedObjectId.value == id;
        final armed = session != null || tool == CanvasTool.pan;
        if (id == null ||
            bounds == null ||
            style == null ||
            dragging ||
            !armed ||
            !mayEdit(id)) {
          return const SizedBox.shrink();
        }
        final camera = document.camera;
        final anchor = Rect.fromLTWH(
          (bounds.x - camera.x) * camera.zoom,
          (bounds.y - camera.y) * camera.zoom,
          bounds.w * camera.zoom,
          bounds.h * camera.zoom,
        );
        final bottom = MediaQuery.viewInsetsOf(context).bottom;
        return Positioned.fill(
          child: Consumer(
            builder: (context, ref, child) {
              // The floating dock's own margin is outside what it reports.
              final dock =
                  ref.watch(bottomDockReservationProvider) +
                  AppSpacing.s12 +
                  AppSpacing.s8;
              return CustomSingleChildLayout(
                delegate: CanvasSelectionBarLayout(
                  anchor: anchor,
                  bottomInset: [
                    bottom,
                    document.bottomInset,
                    dock,
                  ].reduce((a, b) => a > b ? a : b),
                ),
                child: child,
              );
            },
            child: Focus(
              focusNode: focus,
              child: Semantics(
                container: true,
                label: 'Note style',
                child: Consumer(
                  builder: (context, ref, _) => CanvasSelectionBar(
                    entries: canvasNoteStyleOptions(
                      context: context,
                      ref: ref,
                      style: style,
                      onChanged: (next) => onStyle(id, next),
                    ),
                    groupId: canvasNoteTapGroup,
                    trailing: session == null
                        ? null
                        : _EmojiButton(session: session!),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmojiButton extends StatelessWidget {
  const _EmojiButton({required this.session});

  final CanvasNoteEditSession session;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: AppSizes.rowTouch,
    child: EmojiFieldPicker(
      semanticLabel: 'Insert emoji',
      onSelect: (emoji) {
        session.focusNode.requestFocus();
        insertAtSelection(session.controller, emoji);
      },
      builder: (context, button) => button,
    ),
  );
}
