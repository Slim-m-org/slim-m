// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bytes of one file as a resumable upload reads them: in order, but able
/// to start again at any offset after a part failed.
library;

import 'dart:async';
import 'dart:math' as math;

/// Raised when an upload was cancelled through its [UploadCancelToken].
class UploadCancelled implements Exception {
  const UploadCancelled();

  @override
  String toString() => 'UploadCancelled';
}

/// Lets a caller stop a resumable upload between and inside its parts.
class UploadCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const UploadCancelled();
  }
}

/// A file's bytes, read once front to back in the happy path.
///
/// [open] reads from the start and is all a platform has to offer; [openAt]
/// lets one that can seek (a file on disk) resume without reading the front
/// again. Without it a resume re-reads and discards up to the offset, which
/// is slow for a multi-gigabyte file but only happens after a failure.
class UploadSource {
  UploadSource({required this.open, this.openAt});

  final Stream<List<int>> Function() open;
  final Stream<List<int>> Function(int offset)? openAt;

  StreamIterator<List<int>>? _iterator;
  List<int> _pending = const [];
  int _position = 0;

  /// Exactly [length] bytes starting at [offset].
  ///
  /// The underlying stream stays open between consecutive parts, so a file is
  /// read once. Asking for any other offset reopens it there.
  Stream<List<int>> part(
    int offset,
    int length, {
    UploadCancelToken? cancel,
  }) async* {
    await _seek(offset);
    var remaining = length;
    while (remaining > 0) {
      cancel?.throwIfCancelled();
      final chunk = await _take(remaining);
      remaining -= chunk.length;
      yield chunk;
    }
  }

  /// Drops the open stream; the next [part] reopens it.
  Future<void> close() async {
    final iterator = _iterator;
    _iterator = null;
    _pending = const [];
    await iterator?.cancel();
  }

  Future<void> _seek(int offset) async {
    if (_iterator != null && _position == offset) return;
    await close();
    final at = openAt;
    if (at != null) {
      _iterator = StreamIterator(at(offset));
      _position = offset;
      return;
    }
    _iterator = StreamIterator(open());
    _position = 0;
    var skip = offset;
    while (skip > 0) {
      skip -= (await _take(skip)).length;
    }
  }

  Future<List<int>> _take(int most) async {
    while (_pending.isEmpty) {
      final iterator = _iterator;
      if (iterator == null || !await iterator.moveNext()) {
        throw StateError('the file ended before its declared size');
      }
      _pending = iterator.current;
    }
    final count = math.min(most, _pending.length);
    final chunk =
        count == _pending.length ? _pending : _pending.sublist(0, count);
    _pending = count == _pending.length ? const [] : _pending.sublist(count);
    _position += count;
    return chunk;
  }
}
