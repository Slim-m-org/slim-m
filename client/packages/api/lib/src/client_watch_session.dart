// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'exceptions.dart';
import 'logging/app_log.dart';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The read half of the watch session; the bot that runs the party sets it
/// from its own process. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
extension SlimmApiWatchSession on SlimmApi {
  /// What the room is watching and where it is, or null when nothing is.
  Future<WatchSession?> getWatchSession(String channelId) async {
    try {
      final json = await send('GET', '/channels/$channelId/watch-session');
      return WatchSession.fromJson(json as Map<String, dynamic>);
    } on NotFoundException catch (error, stack) {
      AppLog.swallowed(
          LogTag.auth, 'Could not read the shared watch session', error, stack);
      return null;
    }
  }
}
