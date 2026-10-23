// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// The server's own-network addresses, read once signed in: the `system` tag's
/// `GET /direct-route`.
extension SlimmApiDirectRoute on SlimmApi {
  /// Hands the native shortcut the addresses the server advertises. A
  /// signed-in session is required, so a server never gets this device to dial
  /// anything before the member has chosen to sign in to it.
  Future<void> refreshDirectRoute() async {
    final json = await _send('GET', '/direct-route') as Map<String, dynamic>;
    _route?.advertise([
      for (final entry in json['addresses'] as List<dynamic>? ?? [])
        if (entry is String) entry,
    ]);
  }

  /// Drops pooled LAN connections after the device may have changed network.
  void routeMayHaveChanged() => _route?.invalidate();

  /// Tries the server's own network again at once; see [DirectRoute.retryNow].
  void _retryDirectRoute() => _route?.retryNow();
}
