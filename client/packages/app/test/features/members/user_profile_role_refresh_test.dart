// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A role change re-asks for the profiles it touches, so an open message list
/// and member list repaint a name's colour without a reload: a grant re-asks
/// for that member, a role edit for exactly its holders, and the old entry
/// stays on screen until the answer lands rather than blinking to default.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

class _Server {
  /// Each member's held role ids, and each role's colour.
  final held = <String, List<String>>{
    'ada': ['r-mods'],
    'bob': [],
  };
  final colours = <String, int?>{'r-mods': 1};
  final requests = <Uri>[];

  /// Holds every answer until completed, so a test can look mid-flight.
  Completer<void>? gate;

  Map<String, Object?> profile(String id) => {
    'id': id,
    'username': id,
    'display_name': id,
    'created_at': 0,
    'roles': held[id],
    'role_ids': held[id],
    'role_colors': [for (final r in held[id]!) colours[r]],
  };

  Future<http.Response> answer(http.Request request) async {
    requests.add(request.url);
    await gate?.future;
    final Object body = request.url.path == '/users'
        ? [
            for (final id in request.url.queryParameters['ids']!.split(','))
              profile(id),
          ]
        : profile(request.url.pathSegments.last);
    return http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

({ProviderContainer container, StreamController<ServerEvent> events}) _rig(
  _Server server,
) {
  final events = StreamController<ServerEvent>.broadcast();
  addTearDown(events.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: const TokenPair(
            userId: 'self',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      liveEventsProvider.overrideWithValue(events.stream),
      mockApiOverride(server.answer),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, events: events);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a grant re-asks for that member, keeping the old entry meanwhile',
    () async {
      final server = _Server();
      final rig = _rig(server);
      final batch = rig.container.read(
        batchProfilesControllerProvider.notifier,
      );
      await batch.resolve(['ada']);
      expect(
        rig.container.read(batchProfilesControllerProvider)['ada']!.roleColors,
        [1],
      );

      server
        ..colours['r-new'] = 7
        ..held['ada'] = ['r-new', 'r-mods']
        ..gate = Completer<void>();
      rig.events.add(const MemberRoleChanged(userId: 'ada', roleId: 'r-new'));
      await _settle();
      expect(
        rig.container.read(batchProfilesControllerProvider)['ada']!.roleColors,
        [1],
        reason: 'still drawn in its old colour while the answer is out',
      );

      server.gate!.complete();
      await _settle();
      await _settle();
      expect(
        rig.container.read(batchProfilesControllerProvider)['ada']!.roleColors,
        [7, 1],
      );
    },
  );

  test('a role edit re-asks for exactly the members holding it', () async {
    final server = _Server();
    final rig = _rig(server);
    await rig.container.read(batchProfilesControllerProvider.notifier).resolve([
      'ada',
      'bob',
    ]);
    server.requests.clear();

    server.colours['r-mods'] = 9;
    rig.events.add(const RoleChanged(roleId: 'r-mods'));
    await _settle();
    await _settle();

    expect(server.requests, hasLength(1));
    expect(server.requests.single.queryParameters['ids'], 'ada');
    expect(
      rig.container.read(batchProfilesControllerProvider)['ada']!.roleColors,
      [9],
    );
  });

  test('a live profile override follows a role edit too', () async {
    final server = _Server();
    final rig = _rig(server);
    final overrides = rig.container.read(
      memberProfileOverridesProvider.notifier,
    );
    overrides.applyKnown(UserProfile.fromJson(server.profile('ada')));

    server.colours['r-mods'] = 3;
    rig.events.add(const RoleChanged(roleId: 'r-mods'));
    await _settle();
    await _settle();

    expect(server.requests.map((u) => u.path), ['/users/ada']);
    expect(
      rig.container.read(memberProfileOverridesProvider)['ada']!.roleColors,
      [3],
    );
  });
}
