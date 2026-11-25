// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Runs async jobs one after another, in the order they were asked for.
library;

import 'dart:async';

/// A job that fails does not stop the ones queued behind it.
class SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() job) {
    final result = _tail.then((_) => job());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
