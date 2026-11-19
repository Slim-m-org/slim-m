// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The open channels whose reader would mark a new message read the moment it
/// shows, so the live path can store it already read in one write instead of
/// raising unread and clearing it a frame later.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One open channel screen, asked as each live message arrives.
abstract interface class ArrivalReader {
  /// Whether a message arriving in [channelId] now would be read on sight.
  bool readsOnArrival(String channelId);

  /// Tells the server, after the store marked [seq] read with the message.
  void readOnArrival(String channelId, int seq);
}

/// The readers mounted in this account.
class ArrivalReaders {
  final _readers = <ArrivalReader>{};

  void add(ArrivalReader reader) => _readers.add(reader);

  void remove(ArrivalReader reader) => _readers.remove(reader);

  /// The reader that would read a message arriving in [channelId] now, if any.
  ArrivalReader? readerFor(String channelId) {
    for (final reader in _readers) {
      if (reader.readsOnArrival(channelId)) return reader;
    }
    return null;
  }
}

final arrivalReadersProvider = Provider<ArrivalReaders>(
  (ref) => ArrivalReaders(),
);
