// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'direct_route.dart';
import 'client.dart';
import 'client_transport.dart';

/// The server's own-network addresses, read once signed in: the `system` tag's
/// `GET /direct-route`.
extension SlimmApiDirectRoute on SlimmApi {
  /// Hands the native shortcut the addresses the server advertises. A
  /// signed-in session is required, so a server never gets this device to dial
  /// anything before the member has chosen to sign in to it.
  Future<void> refreshDirectRoute() async {
    final json = await send('GET', '/direct-route') as Map<String, dynamic>;
    link.route?.advertise([
      for (final entry in json['addresses'] as List<dynamic>? ?? [])
        if (entry is String) entry,
    ]);
  }

  /// Drops pooled LAN connections after the device may have changed network.
  void routeMayHaveChanged() => link.route?.invalidate();

  /// Tries the server's own network again at once; see [DirectRoute.retryNow].
  void retryDirectRoute() => link.route?.retryNow();
}
