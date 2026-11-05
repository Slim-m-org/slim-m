// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The operator alert models, the live frame, and the two routes' bindings.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _tokens = TokenPair(
  userId: 'u',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 0,
);

SlimmApi _api(MockClient client) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(tokens: _tokens),
      httpClient: client,
    );

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

void main() {
  test('admin_alerts.changed parses with no fields', () {
    final event =
        ServerEvent.parse(jsonEncode({'type': 'admin_alerts.changed'}));
    expect(event, isA<AdminAlertsChanged>());
  });

  test('fetchAdminAlerts reads open and recovered alerts and the mute',
      () async {
    String? seen;
    final api = _api(
      MockClient((request) async {
        seen = '${request.method} ${request.url.path}';
        return _json({
          'muted': true,
          'alerts': [
            {
              'kind': 'disk_low',
              'subject': '',
              'detail': 'low',
              'raised_at': 5,
              'resolved_at': null
            },
            {
              'kind': 'backup',
              'subject': '',
              'detail': 'failed',
              'raised_at': 2,
              'resolved_at': 9
            },
          ],
        });
      }),
    );

    final alerts = await api.fetchAdminAlerts();

    expect(seen, 'GET /space/alerts');
    expect(alerts.muted, isTrue);
    expect(alerts.alerts, hasLength(2));
    expect(alerts.open.map((a) => a.kind), ['disk_low']);
    expect(alerts.alerts.last.resolvedAt, 9);
  });

  test('setAdminAlertsMuted puts the flag', () async {
    Map<String, dynamic>? sent;
    String? seen;
    final api = _api(
      MockClient((request) async {
        seen = '${request.method} ${request.url.path}';
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({'alerts': <Object>[], 'muted': true});
      }),
    );

    final alerts = await api.setAdminAlertsMuted(true);

    expect(seen, 'PUT /space/alerts/mute');
    expect(sent, {'muted': true});
    expect(alerts.muted, isTrue);
  });

  test('storage carries the backup status, every state', () {
    for (final (wire, state) in [
      ('not_configured', BackupState.notConfigured),
      ('never', BackupState.never),
      ('verified', BackupState.verified),
      ('failed', BackupState.failed),
      ('unreadable', BackupState.unreadable),
    ]) {
      final backup = SpaceBackupStatus.fromJson({
        'state': wire,
        'stale': false,
        'error': wire == 'failed' ? 'drill: FAIL' : null,
        'verified_at': 10,
        'verified_bytes': 20,
      });
      expect(backup.state, state);
      expect(backup.verifiedAt, 10);
      expect(backup.verifiedBytes, 20);
    }
  });
}
