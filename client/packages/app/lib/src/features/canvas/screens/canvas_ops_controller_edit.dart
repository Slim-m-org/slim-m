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
