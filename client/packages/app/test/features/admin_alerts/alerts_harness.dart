// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mocked server for the operator alert surfaces: the alert list, the mute and Storage.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const manageServerBit = 1 << 15;

Map<String, dynamic> alertJson({
  String kind = 'disk_low',
  String subject = '',
  String detail = 'Only 90 MB are free on the data disk.',
  int raisedAt = 1700000000000,
  int? resolvedAt,
}) => {
  'kind': kind,
  'subject': subject,
  'detail': detail,
  'raised_at': raisedAt,
  'resolved_at': resolvedAt,
};

Map<String, dynamic> storageJson(Map<String, dynamic> backup) => {
  'database_bytes': 500000,
  'database_reclaimable_bytes': 4096,
  'attachment_bytes': 2048,
  'top_channels': <Map<String, dynamic>>[],
  'sweeps': <Map<String, dynamic>>[],
  'backup': backup,
};

/// The server's answers, changeable between pumps.
class FakeServer {
  List<Map<String, dynamic>> alerts = [];
  bool muted = false;
  Map<String, dynamic> backup = {'state': 'never', 'stale': false};
  final requests = <String>[];
  final events = StreamController<api.ServerEvent>.broadcast();

  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add('${request.method} ${request.url.path}');
    switch ((request.method, request.url.path)) {
      case ('GET', '/space/alerts'):
        return _json({'alerts': alerts, 'muted': muted});
      case ('PUT', '/space/alerts/mute'):
        muted =
            (jsonDecode(request.body) as Map<String, dynamic>)['muted'] as bool;
        return _json({'alerts': alerts, 'muted': muted});
      case ('GET', '/space/storage'):
        return _json(storageJson(backup));
    }
    return http.Response('', 404);
  }

  ProviderContainer container({required int permissions}) {
    final client = MockClient(handle);
    return ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        meProvider.overrideWith(
          (ref) async => api.Me(
            id: 'admin',
            username: 'admin',
            displayName: 'Admin',
            createdAt: 0,
            permissions: permissions,
          ),
        ),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
  }
}
