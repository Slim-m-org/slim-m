// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The style bar over the selected note or text box, and over a note being typed in.
///
/// It shows for a note this person may edit, while the Move tool is armed and the note is not being dragged.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart'
    show AppIconButton, AppIcons, AppSizes, AppSpacing;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../providers/dock_reservation.dart';
import '../../emoji/widgets/emoji_picker.dart';
import '../providers/canvas_edge_style.dart';
import '../widgets/canvas_note_editor.dart';
import '../widgets/canvas_note_limits.dart';
import '../widgets/canvas_note_style_options.dart';
import '../widgets/canvas_selection_bar.dart';
import '../widgets/canvas_text_style_options.dart';

class CanvasNoteBarLayer extends ConsumerWidget {
  const CanvasNoteBarLayer({
    super.key,
    required this.document,
    required this.tool,
    required this.session,
    required this.mayEdit,
    required this.onStyle,
    required this.onTextStyle,
    this.textEditing = false,
    this.focus,
  });

  final CanvasDocument document;
  final CanvasTool tool;

  /// The note being typed in, whose text the bar's emoji button inserts into.
  final CanvasNoteEditSession? session;

  /// Whether this person may restyle the note: its author or a canvas manager, and it is not locked.
  final bool Function(String id) mayEdit;
  final void Function(String id, CanvasNoteStyle style) onStyle;

  /// Restyles the text box [id]: only the size or only the colour key given.
  final void Function(String id, {String? size, String? colorKey}) onTextStyle;

  /// True while a text box is typed in: its own editor carries the bar then.
  final bool textEditing;

  /// Lets the object menu's Style item put the keyboard on the bar.
  final FocusNode? focus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styled = ref.watch(canvasNoteStyleSupportedProvider);
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
        final box = id == null ? null : document.textBoxOf(id);
        final dragging = document.elevatedObjectId.value == id;
        final armed = session != null || tool == CanvasTool.pan;
        if (id == null ||
            bounds == null ||
            (style == null && box == null) ||
            (box == null && !styled && session == null) ||
            (box != null && textEditing) ||
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
                label: box == null ? 'Note style' : 'Text style',
                child: Consumer(
                  builder: (context, ref, _) => CanvasSelectionBar(
                    entries: box != null
                        ? canvasTextStyleOptions(
                            context: context,
                            ref: ref,
                            size: box.size,
                            colorKey: box.colorKey,
                            onSize: (size) => onTextStyle(id, size: size),
                            onColour: (key) => onTextStyle(id, colorKey: key),
                          )
                        : !styled
                        ? const []
                        : canvasNoteStyleOptions(
                            context: context,
                            ref: ref,
                            style: style!,
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

  void _insert(String emoji) {
    session.focusNode.requestFocus();
    if (!insertEmojiWithinNoteCap(session.controller, emoji)) {
      session.refusals.value++;
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: AppSizes.rowTouch,
    child: EmojiPickerButton(
      alignEnd: true,
      tapGroupId: canvasNoteTapGroup,
      onSelect: _insert,
      triggerBuilder: (context, toggle) => AppIconButton(
        icon: AppIcons.smile,
        semanticLabel: 'Insert emoji',
        tooltip: 'Insert emoji',
        onPressed: toggle,
      ),
    ),
  );
}
