// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a call's peer connections gather on Windows, where any app that opens
/// a listening socket makes the firewall ask the user to allow it.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Whether [configuration] names a relay reached over TCP or TLS, which carries
/// a call through a network that blocks UDP without the client listening.
bool offersTcpRelay(Map<String, dynamic> configuration) {
  final servers = configuration['iceServers'];
  if (servers is! List) return false;
  return servers.whereType<Map<Object?, Object?>>().any(
        (server) => _urls(server).any(_isTcpRelay),
      );
}

Iterable<String> _urls(Map<Object?, Object?> server) sync* {
  for (final key in const ['urls', 'url']) {
    final value = server[key];
    if (value is String) yield value;
    if (value is List) yield* value.whereType<String>();
  }
}

bool _isTcpRelay(String url) {
  final lower = url.toLowerCase();
  return lower.startsWith('turns:') ||
      (lower.startsWith('turn:') && lower.contains('transport=tcp'));
}

/// [configuration] without TCP candidates when a TCP relay stands in for them.
///
/// A passive TCP candidate listens on every interface. Without such a relay
/// the candidates stay, as the SFU's TCP port is then the only fallback.
Map<String, dynamic> callPeerConfiguration(
  Map<String, dynamic> configuration,
) =>
    offersTcpRelay(configuration)
        ? {...configuration, 'tcpCandidatePolicy': 'disabled'}
        : configuration;

/// Creates a call's peer connection from [callPeerConfiguration].
Future<rtc.RTCPeerConnection> createCallPeerConnection(
  Map<String, dynamic> configuration, [
  Map<String, dynamic> constraints = const {},
]) =>
    rtc.createPeerConnection(callPeerConfiguration(configuration), constraints);
