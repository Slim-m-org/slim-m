// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A connector's wire fields: the manifest's ask, the installed approval and
/// the token the install answer carries once (all absent for a WASM module),
/// and the binding a connector answers its runs with.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _manifest([Map<String, dynamic> extra = const {}]) => {
      'id': 'jellyfin',
      'name': 'Jellyfin',
      'version': '0.1.0',
      'summary': 's',
      'artifact': {'kind': 'connector', 'path': '', 'sha256': ''},
      'runtime': {'backend': 'connector', 'limits': <String, Object>{}},
      'permissions': <Object>[],
      'capabilities': <Object>[],
      'extension_points': <Object>[],
      ...extra,
    };

Map<String, dynamic> _installed([Map<String, dynamic> extra = const {}]) => {
      'id': 'jellyfin',
      'name': 'Jellyfin',
      'version': '0.1.0',
      'artifact_sha256': '',
      'approved_capabilities': <String>[],
      'extension_points': <Object>[],
      'enabled': true,
      'installed_at': 1,
      ...extra,
    };

void main() {
  test('a connector manifest carries what its token asks for', () {
    final m = DockManifest.fromJson(_manifest({
      'provider': 'connector',
      'connector': {'permissions': 6},
    }));
    expect(m.isConnector, isTrue);
    expect(m.connectorPermissions, 6);
  });

  test('a module, or a connector block without the provider, is not one', () {
    expect(DockManifest.fromJson(_manifest()).isConnector, isFalse);
    final stray = DockManifest.fromJson(_manifest({
      'connector': {'permissions': 6},
    }));
    expect(stray.isConnector, isFalse);
  });

  test('an installed connector carries its approval and, once, its token', () {
    final m = InstalledDockModule.fromJson(_installed({
      'provider': 'connector',
      'connector_permissions': 2,
      'connector_token': 'slimbot_x',
    }));
    expect(m.isConnector, isTrue);
    expect(m.connectorPermissions, 2);
    expect(m.connectorToken, 'slimbot_x');
    final listed = InstalledDockModule.fromJson(_installed());
    expect(listed.isConnector, isFalse);
    expect(listed.connectorToken, isNull);
  });

  test('a connector reads its own settings, nulls included', () {
    final me = ConnectorSelf.fromJson({
      'module_id': 'jellyfin',
      'name': 'Jellyfin',
      'version': '0.1.0',
      'permissions': 6,
      'settings': {'api_key': 'k', 'server_url': null},
    });
    expect(me.settings['api_key'], 'k');
    expect(me.settings.containsKey('server_url'), isTrue);
    expect(me.permissions, 6);
  });

  test('a connector answers a run at its own path, with the answer as sent',
      () async {
    String? seen;
    Object? body;
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        seen = '${request.method} ${request.url.path}';
        body = jsonDecode(request.body);
        return http.Response('', 204);
      }),
    );
    await api.answerConnectorRun('r1', ok: true, output: 'up');
    expect(seen, 'POST /connectors/me/runs/r1');
    expect(body, {'ok': true, 'output': 'up'});
  });
}
