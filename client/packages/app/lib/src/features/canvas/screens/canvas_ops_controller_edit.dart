// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_ops_controller.dart';

/// One note edit and the text it replaced, which an undo puts back.
class _EditEntry extends _UndoEntry {
  _EditEntry(this.objectId, this.fromText);

  final String objectId;
  final String fromText;
}

/// The text an undone edit left, which a redo writes again.
class _RedoEdit extends _RedoEntry {
  _RedoEdit(this.objectId, this.toText);

  final String objectId;
  final String toText;
}

/// Editing a placed note, sharing the undo ledger the other gestures use.
extension CanvasOpsControllerEdit on CanvasOpsController {
  /// Replaces [objectId]'s text, shown at once and pushed onto the undo
  /// stack once the server accepts it. Returns whether the text changed.
  Future<bool> editNote(String objectId, String text) async {
    final before = document.noteTextOf(objectId);
    if (before == null || before == text || isLocked(objectId)) return false;
    final submitted = await _editTo(
      objectId,
      text,
      'That note could not be edited.',
    );
    if (submitted == null) return false;
    _pushUndo(_EditEntry(objectId, submitted));
    return true;
  }

  Future<_RedoEntry?> _undoEdit(String objectId, String text) async {
    final before = await _editTo(objectId, text, 'That could not be undone.');
    return before == null ? null : _RedoEdit(objectId, before);
  }

  Future<_UndoEntry?> _redoEdit(String objectId, String text) async {
    final before = await _editTo(objectId, text, 'That could not be redone.');
    return before == null ? null : _EditEntry(objectId, before);
  }

  /// Writes [text] locally first and returns the text it replaced, or null when the request failed (old text restored) or the note is gone; longer text also grows the box.
  Future<String?> _editTo(
    String objectId,
    String text,
    String errorMessage,
  ) async {
    final before = document.noteTextOf(objectId);
    if (before == null) return null;
    document.setNoteText(objectId, text);
    document.refresh();
    try {
      await _sendObjectOp(
        objectId,
        (id) => client.submitCanvasOp(
          channelId,
          id: id,
          kind: 'edit',
          objectId: objectId,
          props: {
            'text': text,
            // An edit replaces the props wholesale, so the size has to travel with it.
            'font_size': ?document.noteFontSizeOf(objectId),
          },
        ),
      );
    } on api.ApiException catch (error) {
      if (document.noteTextOf(objectId) == text) {
        document.setNoteText(objectId, before);
        document.refresh();
      }
      _settleUnknownOutcome(error);
      onError(errorMessage);
      return null;
    }
    await _regrowNote(objectId, text);
    return before;
  }

  /// Never shrinks: a box someone sized by hand keeps its height.
  Future<void> _regrowNote(String objectId, String text) async {
    final bounds = document.objectBounds(objectId);
    if (bounds == null) return;
    final box = noteBoxFor(
      text,
      width: bounds.w,
      minHeight: bounds.h,
      fontSize: noteFontSizeForWidth(bounds.w),
    );
    if (box.height <= bounds.h) return;
    final to = document.boxOnBoard(
      objectId,
      bounds.x,
      bounds.y,
      bounds.w,
      box.height,
    );
    document.moveObject(objectId, to.x, to.y, to.w, to.h);
    document.refresh();
    await _commitBounds(
      objectId,
      bounds,
      to,
      'That note could not be resized.',
      record: false,
    );
  }
}

/// One text box edit and the content and style it replaced, which an undo puts back.
class _TextEditEntry extends _UndoEntry {
  _TextEditEntry(this.objectId, this.from);

  final String objectId;
  final CanvasTextProps from;
}

/// The content and style an undone text edit left, which a redo writes again.
class _RedoTextEdit extends _RedoEntry {
  _RedoTextEdit(this.objectId, this.to);

  final String objectId;
  final CanvasTextProps to;
}

/// Editing a placed text box: its text, font step and colour travel together as one edit.
extension CanvasOpsControllerTextEdit on CanvasOpsController {
  CanvasTextProps? _textPropsOf(String objectId) {
    final box = document.textBoxOf(objectId);
    return box == null
        ? null
        : CanvasTextProps(
            text: box.text,
            size: box.size,
            colorKey: box.colorKey,
          );
  }

  /// Replaces [objectId]'s props, shown at once and pushed onto the undo stack once the server accepts it. Returns whether anything changed.
  Future<bool> editText(String objectId, CanvasTextProps next) async {
    final before = _textPropsOf(objectId);
    if (before == null || before == next || isLocked(objectId)) return false;
    final submitted = await _textEditTo(
      objectId,
      next,
      'That text could not be edited.',
    );
    if (submitted == null) return false;
    _pushUndo(_TextEditEntry(objectId, submitted));
    return true;
  }

  Future<_RedoEntry?> _undoTextEdit(
    String objectId,
    CanvasTextProps props,
  ) async {
    final before = await _textEditTo(
      objectId,
      props,
      'That could not be undone.',
    );
    return before == null ? null : _RedoTextEdit(objectId, before);
  }

  Future<_UndoEntry?> _redoTextEdit(
    String objectId,
    CanvasTextProps props,
  ) async {
    final before = await _textEditTo(
      objectId,
      props,
      'That could not be redone.',
    );
    return before == null ? null : _TextEditEntry(objectId, before);
  }

  /// Writes [next] locally first and returns what it replaced, or null when the request failed (old props restored) or the box is gone.
  Future<CanvasTextProps?> _textEditTo(
    String objectId,
    CanvasTextProps next,
    String errorMessage,
  ) async {
    final before = _textPropsOf(objectId);
    if (before == null) return null;
    _applyTextProps(objectId, next);
    try {
      await _sendObjectOp(
        objectId,
        (id) => client.submitCanvasOp(
          channelId,
          id: id,
          kind: 'edit',
          objectId: objectId,
          props: next.toWire(),
        ),
      );
    } on api.ApiException catch (error) {
      if (_textPropsOf(objectId) == next) _applyTextProps(objectId, before);
      _settleUnknownOutcome(error);
      onError(errorMessage);
      return null;
    }
    await _refitText(objectId, next);
    return before;
  }

  void _applyTextProps(String objectId, CanvasTextProps props) {
    document
      ..setTextBox(
        objectId,
        text: props.text,
        size: props.size,
        colorKey: props.colorKey,
      )
      ..refresh();
  }

  /// A text box is exactly as tall as its lines, so a longer or larger text grows it and a shorter one shrinks it.
  Future<void> _refitText(String objectId, CanvasTextProps props) async {
    final bounds = document.objectBounds(objectId);
    if (bounds == null) return;
    final fitted = textBoxFor(props, width: bounds.w).height;
    if ((fitted - bounds.h).abs() < 0.5) return;
    final to = document.boxOnBoard(
      objectId,
      bounds.x,
      bounds.y,
      bounds.w,
      fitted,
    );
    document
      ..moveObject(objectId, to.x, to.y, to.w, to.h)
      ..refresh();
    await _commitBounds(
      objectId,
      bounds,
      to,
      'That text could not be resized.',
      record: false,
    );
  }
}

/// One edge edit and the props it replaced, which an undo writes back.
class _EdgeEditEntry extends _UndoEntry {
  _EdgeEditEntry(this.objectId, this.inverse);

  final String objectId;
  final Map<String, Object?> inverse;
}

/// The props an undone edge edit left, which a redo writes again.
class _RedoEdgeEdit extends _RedoEntry {
  _RedoEdgeEdit(this.objectId, this.change);

  final String objectId;
  final Map<String, Object?> change;
}

/// Editing and erasing a placed edge (decision 0137), sharing the undo ledger the other gestures use.
extension CanvasOpsControllerEdges on CanvasOpsController {
  /// Applies [change] to the edge at once and sends it: an absent key keeps its value and null deletes it.
  /// Returns whether anything changed; one undo entry per call.
  Future<bool> editEdge(String objectId, Map<String, Object?> change) async {
    if (isLocked(objectId)) return false;
    final inverse = await _edgeEditTo(
      objectId,
      change,
      'That connection could not be edited.',
    );
    if (inverse == null || inverse.isEmpty) return false;
    _pushUndo(_EdgeEditEntry(objectId, inverse));
    return true;
  }

  Future<_RedoEntry?> _undoEdgeEdit(
    String objectId,
    Map<String, Object?> inverse,
  ) async {
    final change = await _edgeEditTo(
      objectId,
      inverse,
      'That could not be undone.',
    );
    return change == null ? null : _RedoEdgeEdit(objectId, change);
  }

  Future<_UndoEntry?> _redoEdgeEdit(
    String objectId,
    Map<String, Object?> change,
  ) async {
    final inverse = await _edgeEditTo(
      objectId,
      change,
      'That could not be redone.',
    );
    return inverse == null ? null : _EdgeEditEntry(objectId, inverse);
  }

  /// Writes [change] locally first and returns the props that put it back, or null when the edge is gone or the request failed (old props restored).
  Future<Map<String, Object?>?> _edgeEditTo(
    String objectId,
    Map<String, Object?> change,
    String errorMessage,
  ) async {
    final edges = document.edges;
    final held = edges.liveEdge(objectId)?.spec.toProps();
    if (held == null) return null;
    final inverse = {for (final key in change.keys) key: held[key]};
    if (!edges.applyEdited(objectId, change)) return const {};
    try {
      await _sendObjectOp(
        objectId,
        (id) => client.submitCanvasOp(
          channelId,
          id: id,
          kind: 'edit',
          objectId: objectId,
          props: change,
        ),
      );
    } on api.ApiException catch (error) {
      edges.applyEdited(objectId, inverse);
      _settleUnknownOutcome(error);
      onError(errorMessage);
      return null;
    }
    return inverse;
  }

  /// Erases one edge for good measure of undo: hidden at once, removed on the server, restorable.
  Future<bool> eraseEdge(String objectId) async {
    if (isLocked(objectId) || !document.edges.isAlive(objectId)) return false;
    document
      ..removeObject(objectId)
      ..refresh();
    final removed = await _submitRemove([
      objectId,
    ], errorMessage: 'That connection could not be deleted.');
    if (!removed.ok) return false;
    if (removed.opIds.isNotEmpty) {
      _pushUndo(_EraseEntry(removed.opIds, [objectId]));
    }
    return true;
  }
}
