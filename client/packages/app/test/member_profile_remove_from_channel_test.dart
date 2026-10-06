// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Remove from #channel" on the member card: gated on MANAGE_ROLES in that
/// channel (the permissions grid's own gate), confirmed, and written as a
/// member overwrite that keeps whatever the member already had.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/reduced_motion_harness.dart';
import 'voice_controller_harness.dart' show tokens;

const _channelId = 'channel-secret';

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
);

const _adminRole = api.Role(
  id: 'role-admin',
  name: 'Admin',
  permissions: Perm.administrator,
  isEveryone: false,
  createdAt: 0,
);

data.Channel _channel(String kind) => data.Channel(
  id: _channelId,
  name: 'secret',
  kind: kind,
  createdAt: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  isPersonalSpace: false,
  joinMuted: false,
  position: 0,
  slowModeSeconds: 0,
);

({ProviderContainer container, List<http.Request> writes}) _wire({
  required int channelPermissions,
  String kind = 'text',
  api.Me? selfProfile,
  bool failWrite = false,
  List<api.Role> roles = const <api.Role>[],
  api.UserProfile member = _other,
}) {
  final writes = <http.Request>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      myPermissionsProvider.overrideWithValue(0),
      membersProvider.overrideWith((ref) async => [member]),
      rolesProvider.overrideWith((ref) async => roles),
      channelByIdProvider.overrideWith(
        (ref, id) => Stream.value(_channel(kind)),
      ),
      if (selfProfile != null)
        meProvider.overrideWith((ref) async => selfProfile),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            const json = {'content-type': 'application/json'};
            final path = request.url.path;
            if (path == '/channels/$_channelId/permissions') {
              return http.Response(
                jsonEncode({'permissions': channelPermissions}),
                200,
                headers: json,
              );
            }
            if (path == '/channels/$_channelId/overwrites') {
              if (request.method == 'PUT') {
                writes.add(request);
                if (failWrite) return http.Response('{}', 500, headers: json);
              }
              return http.Response(
                jsonEncode({
                  'overwrites': [
                    {
                      'kind': 'member',
                      'id': _other.id,
                      'allow': Perm.viewChannel | Perm.sendMessages,
                      'deny': Perm.attachFiles,
                    },
                  ],
                }),
                200,
                headers: json,
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, writes: writes);
}

Future<void> _open(
  WidgetTester tester,
  ProviderContainer container, {
  api.UserProfile profile = _other,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    reducedMotionApp(
      container: container,
      child: MemberProfileBody(
        profile: profile,
        compact: false,
        channelId: _channelId,
        onDone: () {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  const label = 'Remove from #secret';

  testWidgets('hidden without MANAGE_ROLES in that channel', (tester) async {
    final wired = _wire(channelPermissions: Perm.viewChannel);
    await _open(tester, wired.container);
    expect(find.text(label), findsNothing);
  });

  testWidgets('hidden for a member who holds administrator', (tester) async {
    const admin = api.UserProfile(
      id: 'user-maya',
      username: 'maya',
      displayName: 'maya',
      createdAt: 0,
      roleIds: ['role-admin'],
    );
    final wired = _wire(
      channelPermissions: Perm.manageRoles,
      roles: const [_adminRole],
      member: admin,
    );
    await _open(tester, wired.container, profile: admin);
    expect(find.text(label), findsNothing);
  });

  testWidgets('hidden against yourself', (tester) async {
    final wired = _wire(
      channelPermissions: Perm.manageRoles,
      selfProfile: api.Me(
        id: _other.id,
        username: _other.username,
        displayName: _other.displayName,
        createdAt: 0,
        permissions: 0,
      ),
    );
    await _open(tester, wired.container);
    expect(find.text(label), findsNothing);
  });

  testWidgets('confirming denies view and keeps the other bits', (
    tester,
  ) async {
    final wired = _wire(channelPermissions: Perm.manageRoles);
    await _open(tester, wired.container);
    expect(find.text(label), findsOneWidget);

    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.text('Remove maya from #secret?'), findsOneWidget);
    expect(wired.writes, isEmpty, reason: 'nothing is written before confirm');

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    final body = jsonDecode(wired.writes.single.body) as Map<String, dynamic>;
    final entry = (body['overwrites'] as List).single as Map<String, dynamic>;
    expect(entry['kind'], 'member');
    expect(entry['id'], _other.id);
    expect(entry['deny'], Perm.attachFiles | Perm.viewChannel);
    expect(entry['allow'], Perm.sendMessages);
  });

  testWidgets('a voice channel also denies connect', (tester) async {
    final wired = _wire(channelPermissions: Perm.manageRoles, kind: 'voice');
    await _open(tester, wired.container);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    final body = jsonDecode(wired.writes.single.body) as Map<String, dynamic>;
    final entry = (body['overwrites'] as List).single as Map<String, dynamic>;
    expect(entry['deny'], Perm.attachFiles | Perm.viewChannel | Perm.connect);
  });

  testWidgets('cancelling writes nothing', (tester) async {
    final wired = _wire(channelPermissions: Perm.manageRoles);
    await _open(tester, wired.container);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(wired.writes, isEmpty);
  });

  testWidgets('a refused write shows an error state, not a snackbar', (
    tester,
  ) async {
    final wired = _wire(channelPermissions: Perm.manageRoles, failWrite: true);
    await _open(tester, wired.container);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });
}
