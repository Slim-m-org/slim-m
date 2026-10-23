// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's profile section reaches both member cards from the slots route,
/// and a failed or empty answer leaves the card exactly as it was.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/module_profile_slots.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/features/members/widgets/module_profile_slots.dart';
import 'package:slimm_app/src/features/voice/providers/member_voice_channel.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.UserProfile _user(String id) =>
    api.UserProfile(id: id, username: id, displayName: id, createdAt: 0);

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

final _sections = {
  'sections': [
    {
      'module_id': 'xp',
      'name': 'level',
      'title': 'Level',
      'nodes': [
        {'type': 'text', 'text': 'Level 12'},
        {'type': 'progress', 'value': 3, 'max': 10},
      ],
    },
    {'module_id': 'quiet', 'name': 'empty', 'title': 'Nothing here'},
  ],
};

Future<List<String>> _pumpCard(
  WidgetTester tester,
  String userId,
  Future<http.Response> Function(http.Request) answer,
) async {
  final paths = <String>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        myPermissionsProvider.overrideWithValue(0),
        membersProvider.overrideWith((ref) async => const []),
        rolesProvider.overrideWith((ref) async => const <api.Role>[]),
        storeProvider.overrideWith((ref) async => MessageStore(db)),
        visibleVoiceChannelsProvider.overrideWith(
          (ref) => const Stream.empty(),
        ),
        mockApiOverride((request) {
          paths.add(request.url.path);
          return answer(request);
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MemberProfileBody(
              profile: _user(userId),
              compact: false,
              onDone: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return paths;
}

Future<http.Response> _slots(http.Request request) async =>
    request.url.path.startsWith('/space/dock/slots/profile/')
    ? _json(200, _sections)
    : _json(404, {'error': 'unexpected'});

void main() {
  for (final (label, id) in const [('other', 'maya'), ('own', 'self')]) {
    testWidgets("a module section shows on the $label card", (tester) async {
      final paths = await _pumpCard(tester, id, _slots);

      expect(paths, contains('/space/dock/slots/profile/$id'));
      expect(find.text('Level'), findsOneWidget);
      expect(find.text('Level 12'), findsOneWidget);
      expect(find.text('3 / 10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a section with nothing to draw is not shown', (tester) async {
    await _pumpCard(tester, 'maya', _slots);

    expect(find.text('Nothing here'), findsNothing);
  });

  testWidgets('a failed fetch hides the section and throws nothing', (
    tester,
  ) async {
    await _pumpCard(tester, 'maya', (_) async => _json(500, {'error': 'x'}));

    expect(find.byType(ModuleProfileSlots), findsOneWidget);
    expect(find.text('Level'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no sections at all leaves no trace', (tester) async {
    await _pumpCard(
      tester,
      'maya',
      (_) async => _json(200, {'sections': <Object>[]}),
    );

    final size = tester.getSize(find.byType(ModuleProfileSlots));
    expect(size.height, 0);
  });

  test('the provider answers an empty list when the fetch fails', () async {
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((_) async => _json(500, {'error': 'x'})),
      ],
    );
    addTearDown(container.dispose);

    final sections = await container.read(
      moduleProfileSlotsProvider('u').future,
    );

    expect(sections, isEmpty);
  });
}
