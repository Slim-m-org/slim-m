// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first-run setup's wire types and the two routes that carry them.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

SlimmApi _api(MockClient client) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(tokens: _tokens),
      httpClient: client,
    );

Map<String, dynamic> _body({
  bool claimedByMe = true,
  bool completed = false,
  int? memoryLimit,
  bool voice = true,
}) =>
    {
      'claimed_by_me': claimedByMe,
      'completed': completed,
      'capacity': {
        'cores': 4,
        'memory_total_bytes': 8 * 1024 * 1024 * 1024,
        'memory_limit_bytes': memoryLimit,
        'disk_free_bytes': 100,
        'disk_total_bytes': 400,
        'voice_configured': true,
        'estimate': {
          'binding': 'connections',
          'connection_limit': 1024,
          'members_min': 340,
          'members_max': 770,
          'voice_min': voice ? 40 : null,
          'voice_max': voice ? 70 : null,
        },
      },
    };

void main() {
  test('GET /space/setup reads the machine and the estimate', () async {
    String? path;
    final api = _api(
      MockClient((request) async {
        path = request.url.path;
        return http.Response(jsonEncode(_body()), 200);
      }),
    );
    final setup = await api.spaceSetup();
    expect(path, '/space/setup');
    expect(setup.capacity.cores, 4);
    expect(setup.capacity.estimate.membersMin, 340);
    expect(setup.capacity.estimate.voiceMax, 70);
    expect(setup.capacity.diskFreeBytes, 100);
  });

  test('setup is owed to the claiming admin until it is finished', () {
    expect(SpaceSetup.fromJson(_body()).owed, isTrue);
    expect(SpaceSetup.fromJson(_body(completed: true)).owed, isFalse);
    expect(SpaceSetup.fromJson(_body(claimedByMe: false)).owed, isFalse);
  });

  test('a limit below the host memory is the memory the server can use', () {
    final limited = SpaceSetup.fromJson(_body(memoryLimit: 1 << 30));
    expect(limited.capacity.usableMemoryBytes, 1 << 30);
    final free = SpaceSetup.fromJson(_body());
    expect(free.capacity.usableMemoryBytes, 8 * 1024 * 1024 * 1024);
  });

  test('absent voice figures read as null, not zero', () {
    final json = _body(voice: false);
    final setup = SpaceSetup.fromJson(json);
    expect(setup.capacity.estimate.voiceMin, isNull);
    expect(setup.capacity.estimate.voiceMax, isNull);
  });

  test('completing posts to the complete route', () async {
    String? method;
    String? path;
    final api = _api(
      MockClient((request) async {
        method = request.method;
        path = request.url.path;
        return http.Response('', 204);
      }),
    );
    await api.completeSpaceSetup();
    expect((method, path), ('POST', '/space/setup/complete'));
  });
}
