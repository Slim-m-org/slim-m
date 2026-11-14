// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The newest message still standing in a channel, which is what unread is measured against.
library;

import 'database.dart';

/// [Channel.liveSeq] with the sync cursor standing in on a row written before it was tracked.
extension StandingChannel on Channel {
  /// Above `lastReadSeq` exactly when a message the reader has not seen is still there.
  int get standingSeq => liveSeq ?? cursor;
}
