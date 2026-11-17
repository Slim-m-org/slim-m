// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one rule every entry point that commits to a server address must
/// apply: plain http is only for a network that never crosses the internet.
library;

/// Whether an address is on the loopback interface or a private network.
///
/// These are the ranges where plain http is reasonable: a self-hosted box on
/// a home network cannot get a public certificate for an address that does
/// not resolve publicly, and the traffic never crosses the internet anyway.
bool isLocalAddress(Uri address) {
  final host = address.host;
  if (host == 'localhost' || host.endsWith('.local')) return true;

  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((o) => o == null || o < 0 || o > 255)) return false;

  final [a, b, _, _] = octets.cast<int>();
  // 127/8 loopback, 10/8, 192.168/16, and 172.16/12 private ranges.
  return a == 127 ||
      a == 10 ||
      (a == 192 && b == 168) ||
      (a == 172 && b >= 16 && b <= 31);
}

/// Refuses a public http address; returns null when [address] is allowed.
///
/// Typing a server address by hand is a trust decision, so it is stated
/// rather than implied: whoever runs it can read everything sent there.
/// https is required over the internet, but not on a local network - see
/// [isLocalAddress] for why plain http is accepted there. Shared by every
/// entry point that commits to a server address, so the rule cannot drift
/// between the sign-in field, the invite dialog and the manual dialog again.
String? requireSecureScheme(Uri address) {
  if (address.scheme == 'https' || isLocalAddress(address)) return null;
  return 'Use https for a Space on the internet. Plain http only works on '
      'your own network.';
}
