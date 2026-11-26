// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas undo and redo stacks, and the loop that walks them.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

/// How many gestures [CanvasHistory] can reverse. About the product, not the
/// memory: a deeper stack that dies on pane close is a promise the UI cannot keep.
@visibleForTesting
const int undoStackDepth = 32;

/// What [CanvasHistory] needs from the controller that owns the entries.
class CanvasHistoryHost<U extends Object, R extends Object> {
  const CanvasHistoryHost({
    required this.undoStep,
    required this.redoStep,
    required this.isSkipped,
    required this.isNoRedo,
    required this.isNoUndo,
    required this.isDisposed,
    required this.onError,
  });

  /// Reverses [U]; null means it failed, unless the entry is marked gone.
  final Future<R?> Function(U entry) undoStep;

  /// Re-applies [R]; null means it failed, unless the entry is marked gone.
  final Future<U?> Function(R entry) redoStep;

  /// A reversal that found nothing left to reverse, so the next entry runs.
  final bool Function(R redo) isSkipped;

  /// A reversal that succeeded and has no opposite to remember.
  final bool Function(R redo) isNoRedo;

  /// A re-application that succeeded and has no opposite to remember.
  final bool Function(U undo) isNoUndo;
  final bool Function() isDisposed;
  final void Function(String message) onError;
}

/// Undo and redo stacks that drop an entry only once its reversal succeeded,
/// or once its object turned out to be deleted elsewhere.
class CanvasHistory<U extends Object, R extends Object> {
  CanvasHistory(this._host);

  final CanvasHistoryHost<U, R> _host;
  final Queue<U> _undoStack = Queue<U>();
  final Queue<R> _redoStack = Queue<R>();

  // Bumped by every fresh edit so an undo still in flight cannot refill a redo stack the edit just cleared.
  int _editEpoch = 0;
  bool _busy = false;
  bool _entryGone = false;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  bool get isBusy => _busy;

  /// Set when a history step found its object deleted elsewhere, so the entry is dropped rather than retried.
  bool get entryGone => _entryGone;

  void clearGone() => _entryGone = false;

  /// Marks the running history step's entry as having nothing left to do.
  void markGone() {
    if (_busy) _entryGone = true;
  }

  void pushUndo(U entry, {bool keepRedo = false}) {
    if (!keepRedo) {
      _editEpoch++;
      _redoStack.clear();
    }
    _undoStack.addLast(entry);
    while (_undoStack.length > undoStackDepth) {
      _undoStack.removeFirst();
    }
  }

  void _pushRedo(R redo) {
    _redoStack.addLast(redo);
    while (_redoStack.length > undoStackDepth) {
      _redoStack.removeFirst();
    }
  }

  /// Reverses the most recent entry and makes it available to [redo].
  Future<void> undo() async {
    if (_busy) return;
    _busy = true;
    try {
      var skipped = 0;
      while (_undoStack.isNotEmpty && !_host.isDisposed()) {
        final epoch = _editEpoch;
        final entry = _undoStack.last;
        _entryGone = false;
        final redo = await _host.undoStep(entry);
        if (redo == null && !_entryGone) return;
        _undoStack.remove(entry);
        if (redo == null || _host.isSkipped(redo)) {
          skipped++;
          continue;
        }
        if (!_host.isNoRedo(redo) && epoch == _editEpoch) _pushRedo(redo);
        return;
      }
      if (skipped > 0) {
        _host.onError('Nothing left to undo is still on the board.');
      }
    } finally {
      _busy = false;
    }
  }

  /// Re-applies the most recently undone entry, or does nothing if there is none.
  Future<void> redo() async {
    if (_busy || _redoStack.isEmpty) return;
    _busy = true;
    var dropped = 0;
    try {
      while (_redoStack.isNotEmpty && !_host.isDisposed()) {
        final entry = _redoStack.last;
        _entryGone = false;
        final undoEntry = await _host.redoStep(entry);
        if (undoEntry == null && !_entryGone) return;
        _redoStack.remove(entry);
        if (undoEntry == null) {
          dropped++;
          continue;
        }
        if (!_host.isNoUndo(undoEntry)) pushUndo(undoEntry, keepRedo: true);
        return;
      }
      if (dropped > 0) {
        _host.onError('Nothing left to redo is still on the board.');
      }
    } finally {
      _busy = false;
    }
  }
}
