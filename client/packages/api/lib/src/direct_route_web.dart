// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser decides how to connect, so the web build never shortcuts.
library;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'direct_route.dart';

DirectRoute createDirectRoute(Uri baseUrl) => _BrowserRoute();

class _BrowserRoute implements DirectRoute {
  @override
  final http.Client httpClient = http.Client();

  @override
  bool get active => false;

  @override
  Stream<bool> get activeChanges => const Stream.empty();

  @override
  void retryNow() {}

  @override
  bool get hasAddresses => false;

  @override
  http.Client? pinnedClient({required bool direct}) =>
      direct ? null : http.Client();

  @override
  void advertise(List<String> addresses) {}

  @override
  WebSocketChannel connectWebSocket(Uri url) => WebSocketChannel.connect(url);
}
