// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note edited where it sits: the note itself is the field, at its own position, size, padding, font and colours.
///
/// The painter leaves the note's text out while it is edited, so this field is the only copy and follows
/// the camera and any remote move every frame. A tap outside the note and its bar, Ctrl or Cmd plus Enter
/// or picking another object commits; Escape cancels. Editing down to nothing cancels, since this field has no way to delete a note.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_inline_emoji_controller.dart';
import 'canvas_note_sizing.dart';
import 'canvas_note_field.dart';

/// What the field says before anything is typed, and what a screen reader calls it.
const String canvasNoteFieldHint = 'What do you want to remember?';

/// The tap region group the field and its style bar share.
final Object canvasNoteTapGroup = Object();

/// The text being edited and where the note stood when editing began.
class CanvasNoteEditSession {
  CanvasNoteEditSession({
    required this.objectId,
    required this.initialText,
    required this.startBounds,
    this.draft,
    Map<String, String> Function()? emojiIndex,
  }) : controller = InlineEmojiController(
         text: initialText,
         index: emojiIndex ?? () => const {},
       ),
       focusNode = FocusNode(),
       baseHeight = startBounds.h {
    controller.selection = TextSelection.collapsed(offset: initialText.length);
  }

  final String objectId;
  final String initialText;

  /// The note's box before it grew to hold what was typed, which a cancel or a commit grows from.
  final ({double x, double y, double w, double h}) startBounds;

  /// Set for a note that exists only here until its text is committed: where it was asked for.
  final CanvasNoteDraft? draft;

  final InlineEmojiController controller;
  final FocusNode focusNode;

  /// Counts the inserts the note's cap refused, so its field can say why.
  final refusals = ValueNotifier<int>(0);

  /// The height the note had before typing grew it, which a commit or cancel gives back.
  double baseHeight;

  /// The height this editor last grew the note to; a different height since then came from someone else.
  double? grownHeight;

  void dispose() {
    controller.dispose();
    focusNode.dispose();
    refusals.dispose();
  }
}

/// A note not placed yet: the spot asked for and the size it was dragged out to, if any.
class CanvasNoteDraft {
  const CanvasNoteDraft({required this.world, this.draggedSize});

  final Offset world;
  final Size? draggedSize;
}

class CanvasNoteEditor extends StatefulWidget {
  const CanvasNoteEditor({
    super.key,
    required this.document,
    required this.session,
    required this.palette,
    required this.onCommit,
    required this.onCancel,
    required this.onGone,
  });

  final CanvasDocument document;
  final CanvasNoteEditSession session;
  final NotePalette palette;
  final ValueChanged<String> onCommit;
  final VoidCallback onCancel;

  /// The note was removed under the editor.
  final VoidCallback onGone;

  @override
  State<CanvasNoteEditor> createState() => _CanvasNoteEditorState();
}

class _CanvasNoteEditorState extends State<CanvasNoteEditor>
    with SingleTickerProviderStateMixin {
  CanvasNoteEditSession get _session => widget.session;
  bool _done = false;
  late final AnimationController _ease = AnimationController(vsync: this);
  Camera? _easeFrom;
  Camera? _easeTo;

  @override
  void initState() {
    super.initState();
    _session.controller.addListener(_grow);
    widget.document.editingObjectId.value = _session.objectId;
    // Asked for, not autofocus alone: the pane's own shortcut focus can still hold it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _session.focusNode.requestFocus();
      _easeToReadable();
    });
  }

  @override
  void dispose() {
    _session.controller.removeListener(_grow);
    _ease.dispose();
    if (!widget.document.isDisposed &&
        widget.document.editingObjectId.value == _session.objectId) {
      widget.document.editingObjectId.value = null;
    }
    super.dispose();
  }

  double _fontWorld(double w, double h) {
    final style =
        widget.document.noteStyleOf(_session.objectId) ??
        const CanvasNoteStyle();
    return noteTextSizeOf(noteFontSizeFor(w, h), style);
  }

  /// Grows the note to hold the raw text as it is typed; the commit grows it again to the rendered layout.
  void _grow() {
    final bounds = widget.document.objectBounds(_session.objectId);
    if (bounds == null) return;
    final style =
        widget.document.noteStyleOf(_session.objectId) ??
        const CanvasNoteStyle();
    final box = noteBoxFor(
      _session.controller.text,
      width: bounds.w,
      minHeight: bounds.h,
      fontSize: noteTextSizeOf(noteFontSizeForWidth(bounds.w), style),
    );
    if (box.height <= bounds.h) return;
    if (bounds.h != _session.grownHeight) _session.baseHeight = bounds.h;
    final to = widget.document.boxOnBoard(
      _session.objectId,
      bounds.x,
      bounds.y,
      bounds.w,
      box.height,
    );
    _session.grownHeight = to.h;
    widget.document
      ..moveObject(_session.objectId, to.x, to.y, to.w, to.h)
      ..refresh();
  }

  /// A note smaller on screen than body text is not typed into: the camera eases in, a move the system makes and so may animate.
  void _easeToReadable() {
    final document = widget.document;
    final bounds = document.objectBounds(_session.objectId);
    if (bounds == null) return;
    final camera = document.camera;
    final screenFont = _fontWorld(bounds.w, bounds.h) * camera.zoom;
    final body = AppText.body.fontSize!;
    if (screenFont >= body) return;
    final zoom = (camera.zoom * body / screenFont).clamp(camera.zoom, maxZoom);
    final center = Offset(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2);
    final view = document.viewport;
    final target = Camera(
      x: center.dx - view.width / (2 * zoom),
      y: center.dy - view.height / (3 * zoom),
      zoom: zoom,
    );
    final duration = AppMotion.reduced(context, AppMotion.base);
    if (duration == Duration.zero) {
      document.setCamera(target);
      return;
    }
    _easeFrom = camera;
    _easeTo = target;
    _ease
      ..duration = duration
      ..addListener(_stepEase)
      ..forward(from: 0);
  }

  void _stepEase() {
    final from = _easeFrom;
    final to = _easeTo;
    if (from == null || to == null) return;
    final t = Curves.easeOut.transform(_ease.value);
    widget.document.setCamera(
      Camera(
        x: from.x + (to.x - from.x) * t,
        y: from.y + (to.y - from.y) * t,
        zoom: from.zoom + (to.zoom - from.zoom) * t,
      ),
    );
  }

  void _commit() {
    if (_done) return;
    final text = _session.controller.text.trim();
    if (text.isEmpty || text == _session.initialText) {
      _cancel();
      return;
    }
    widget.onCommit(text);
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedBuilder(
      animation: widget.document,
      builder: (context, _) {
        final bounds = widget.document.objectBounds(_session.objectId);
        if (bounds == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_done) {
              _done = true;
              widget.onGone();
            }
          });
          return const SizedBox.shrink();
        }
        final camera = widget.document.camera;
        final style =
            widget.document.noteStyleOf(_session.objectId) ??
            const CanvasNoteStyle();
        final fontScreen = _fontWorld(bounds.w, bounds.h) * camera.zoom;
        final pad = noteWorldPad * camera.zoom;
        final rect = Rect.fromLTWH(
          (bounds.x - camera.x) * camera.zoom,
          (bounds.y - camera.y) * camera.zoom,
          bounds.w * camera.zoom,
          bounds.h * camera.zoom,
        );
        _endWhenOutOfView(rect);
        _keepAboveKeyboard(rect, inset);
        final ink = widget.palette.inkOf(style, AppCanvasColors.note);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: TextFieldTapRegion(
                key: const ValueKey('canvas-note-editor-rect'),
                groupId: canvasNoteTapGroup,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _session.focusNode.requestFocus,
                  child: Padding(
                    padding: EdgeInsets.all(pad),
                    child: CanvasNoteField(
                      controller: _session.controller,
                      focusNode: _session.focusNode,
                      onSave: _commit,
                      onCancel: _cancel,
                      hintText: canvasNoteFieldHint,
                      inPlaceStyle: TextStyle(
                        fontFamily: AppFonts.sans,
                        fontSize: fontScreen,
                        height: noteLineHeight,
                        color: ink,
                      ),
                      tapRegionGroupId: canvasNoteTapGroup,
                      onTapOutside: _commit,
                      refusals: _session.refusals,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// A note panned out of the pane is committed (or dropped when empty), so no bar is left editing it from afar.
  void _endWhenOutOfView(Rect rect) {
    final view = widget.document.viewport;
    if (_done || view.isEmpty || (Offset.zero & view).overlaps(rect)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_done) _commit();
    });
  }

  /// A phone's keyboard must not cover the note: the camera pans, never the layout.
  void _keepAboveKeyboard(Rect rect, double inset) {
    if (inset <= 0) return;
    final floor = widget.document.viewport.height - inset - _barRoom;
    final over = rect.bottom - floor;
    if (over <= 0) return;
    final camera = widget.document.camera;
    final shift = math.min(over, math.max(0, rect.top - AppSpacing.s8));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.document.setCamera(
        camera.copyWith(y: camera.y + shift / camera.zoom),
      );
    });
  }

  static const double _barRoom = 64;
}
