// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Places a note or a shape: one request, no serial queue - the same
/// direct-await shape `CanvasImagePaste` already uses for a pasted image,
/// right for a one-off placement rather than the continuous stream
/// `CanvasCommitQueue` exists to serialize a pen's many segments through.
///
/// Deliberately no `CanvasStrokePreviewRelay` frame from either verb: the
/// relay previews a pen stroke's own draft points as they are drawn, and a
/// note or a shape is never drawn at all - a shape is placed at its default
/// box in one request, and a note's text is composed in a sheet with
/// nothing sent until submit, so there is no in-progress state on the wire
/// for anyone else to watch. `CanvasSurface` enforces this structurally: its
/// `onDraftPoint`/`onDraftEnded` callbacks only ever fire for
/// `CanvasTool.pen`, see its own `_down`/`_move`/`_up` switches.
library;

import 'package:flutter/painting.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../ids.dart';
import 'canvas_forbidden_message.dart';
import '../providers/canvas_text_props.dart';
import '../widgets/canvas_text_content.dart';
import 'canvas_note_sizing.dart';
import 'canvas_retry.dart';
import 'canvas_sync.dart';

/// A note's default box: wide enough for a few sentences before wrapping,
/// tall enough that a short note is not mostly empty padding - the floor
/// [noteBoxFor] grows a longer note's height past, never the ceiling.
const double defaultNoteWidth = 330;
const double defaultNoteHeight = 210;

/// The text size a new note is stored with, in world units: legible at the zoom a board fits at, where the old 12 read as 2 to 7 px.
const double defaultNoteFontSize = 18;

/// A shape's default box, centered on the tapped point. Not square, so a
/// freshly placed rectangle or ellipse reads as a shape rather than a dot,
/// and a line or an arrow (the box's own diagonal) is visibly diagonal.
const double defaultShapeWidth = 180;
const double defaultShapeHeight = 120;

class CanvasQuickPlacement {
  CanvasQuickPlacement({
    required this.client,
    required this.channelId,
    required this.document,
    required this.timedOutUntil,
    this.authorId = _noAuthor,
    this.clearedSincePlacement = _neverCleared,
  });

  static bool _neverCleared(api.CanvasObject object) => false;

  static String? _noAuthor() => null;

  /// Who the optimistic copy shows as the author of, until the reply says.
  final String? Function() authorId;

  /// Whether a clear already applied here swept the object while its reply was in flight.
  final bool Function(api.CanvasObject object) clearedSincePlacement;

  bool _inFlight = false;

  final api.SlimmApi client;
  final String channelId;
  final CanvasDocument document;

  /// The caller's own current timeout deadline, Unix milliseconds or null,
  /// read fresh on every refusal rather than captured once at construction -
  /// `CanvasCommitQueue` carries the same shaped field for the same reason.
  final int? Function() timedOutUntil;

  /// Places a note carrying [text], centered at [world]. Text is set once
  /// here and never again - see [CanvasStrokeInput.text]'s own doc for why
  /// there is no edit verb to revise it later. The box is sized to [text]
  /// by [noteBoxFor] rather than the fixed default, so a long note simply
  /// fits instead of clipping inside a box that never grew for it.
  Future<api.CanvasObject?> placeNote(
    Offset world,
    String text, {
    required void Function(String message) onError,
  }) {
    final box = noteBoxFor(
      text,
      width: defaultNoteWidth,
      minHeight: defaultNoteHeight,
      fit: document.board?.size,
      fontSize: defaultNoteFontSize,
    );
    return _place(
      kind: 'note',
      world: world,
      w: box.width,
      h: box.height,
      props: {'text': text, 'font_size': defaultNoteFontSize},
      onError: onError,
    );
  }

  /// Places a text box carrying [props] with its top left at [world], sized to the text.
  Future<api.CanvasObject?> placeText(
    Offset world,
    CanvasTextProps props, {
    required void Function(String message) onError,
  }) {
    final box = textBoxFor(props);
    return _place(
      kind: 'text',
      world: world + Offset(box.width / 2, box.height / 2),
      w: box.width,
      h: box.height,
      props: props.toWire(),
      onError: onError,
    );
  }

  /// Places a [shapeKind] shape centered at [world], sized to [draggedSize]
  /// when the placement gesture was a drag rather than a tap - null keeps
  /// the fixed default box a tap has always placed.
  Future<api.CanvasObject?> placeShape(
    Offset world,
    CanvasShapeKind shapeKind, {
    Size? draggedSize,
    bool flipX = false,
    bool flipY = false,
    required void Function(String message) onError,
  }) => _place(
    kind: 'shape',
    world: world,
    w: draggedSize?.width ?? defaultShapeWidth,
    h: draggedSize?.height ?? defaultShapeHeight,
    props: {
      'shape': canvasShapeKindToWire(shapeKind),
      if (flipX) 'flip_x': true,
      if (flipY) 'flip_y': true,
    },
    onError: onError,
  );

  Future<api.CanvasObject?> _place({
    required String kind,
    required Offset world,
    required double w,
    required double h,
    required Map<String, dynamic> props,
    required void Function(String message) onError,
  }) async {
    // A second tap while one is still being saved would place a second copy.
    if (_inFlight) return null;
    _inFlight = true;
    final box = document.placeOnBoard(
      Rect.fromCenter(center: world, width: w, height: h),
    );
    final id = newCanvasObjectId();
    _show(id, kind, box, props);
    try {
      final placed = await retryCanvasRequest(
        () => client.placeCanvasObject(
          channelId,
          id: id,
          kind: kind,
          x: box.left,
          y: box.top,
          w: box.width,
          h: box.height,
          props: props,
        ),
      );
      final input = canvasStrokeInputFrom(placed);
      if (clearedSincePlacement(placed)) {
        document
          ..removeObject(id)
          ..refresh();
      } else if (input != null) {
        document
          ..applyPlaced(input)
          ..refresh();
      }
      return placed;
    } on api.ApiException catch (error) {
      document
        ..kill(id)
        ..refresh();
      onError(_explain(error, timedOutUntil()));
      return null;
    } finally {
      _inFlight = false;
    }
  }

  /// Shows the object at once under its final id; the reply then settles its order.
  void _show(String id, String kind, Rect box, Map<String, dynamic> props) {
    final input = canvasStrokeInputFrom(
      api.CanvasObject(
        id: id,
        kind: kind,
        zIndex: provisionalLocalZIndex,
        x: box.left,
        y: box.top,
        w: box.width,
        h: box.height,
        props: props,
        authorId: authorId(),
        seq: 0,
        createdAt: 0,
      ),
    );
    if (input == null) return;
    document
      ..applyPlaced(input)
      ..refresh();
  }

  static String _explain(api.ApiException error, int? timedOutUntil) =>
      switch (error) {
        api.ForbiddenException() => canvasDrawForbiddenMessage(timedOutUntil),
        api.ConflictException() => 'This canvas is full.',
        api.BadRequestException() => 'That was refused as too large.',
        _ => 'That could not be placed.',
      };
}
