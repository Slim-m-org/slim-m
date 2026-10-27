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
      await _sendOp(
        (id) => client.submitCanvasOp(
          channelId,
          id: id,
          kind: 'edit',
          objectId: objectId,
          props: {'text': text},
        ),
      );
    } on api.ApiException {
      if (document.noteTextOf(objectId) == text) {
        document.setNoteText(objectId, before);
        document.refresh();
      }
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
    final box = noteBoxFor(text, width: bounds.w, minHeight: bounds.h);
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
      await _sendOp(
        (id) => client.submitCanvasOp(
          channelId,
          id: id,
          kind: 'edit',
          objectId: objectId,
          props: next.toWire(),
        ),
      );
    } on api.ApiException {
      if (_textPropsOf(objectId) == next) _applyTextProps(objectId, before);
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
