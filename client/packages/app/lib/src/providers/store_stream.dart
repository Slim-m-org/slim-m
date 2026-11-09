// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One store-derived drift stream, opened once per store and handed to a
/// `StreamBuilder` on every rebuild.
library;

import 'package:slimm_data/data.dart';

/// A fresh stream per build makes `StreamBuilder` resubscribe, and drift replays its last snapshot into the new listener, so each rebuild rebuilt its subtree a second time.
class StoreStream<T> {
  StoreStream(this._open);

  final Stream<T> Function(MessageStore store) _open;
  MessageStore? _store;
  Stream<T>? _stream;

  Stream<T> of(MessageStore store) {
    if (!identical(_store, store)) {
      _store = store;
      _stream = _open(store);
    }
    return _stream!;
  }
}
