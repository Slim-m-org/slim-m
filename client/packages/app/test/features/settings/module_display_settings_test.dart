// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space-wide module display switches: an admin patches only the one
/// touched, and every member's client re-reads `/version` when told.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/module_display_settings.dart';
import 'package:slimm_app/src/features/settings/screens/admin/module_display_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container(
  Map<String, Object?> Function(http.Request) answer,
  Stream<api.ServerEvent> events,
) {
  final client = MockClient(
    (request) async => http.Response(
      jsonEncode(answer(request)),
      200,
      headers: {'content-type': 'application/json'},
    ),
  );
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events),
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

void main() {
  testWidgets('turning on member-list badges patches only that field', (
    tester,
  ) async {
    var badges = false;
    final patches = <Map<String, dynamic>>[];
    final container = _container((request) {
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patches.add(body);
        badges = body['module_member_badges'] as bool? ?? badges;
      }
      return {
        'join_policy': 'invite',
        'module_member_badges': badges,
        'module_profile_sections': true,
      };
    }, const Stream.empty());
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: ModuleDisplaySection()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    SettingsToggleRow row(String label) => tester.widget<SettingsToggleRow>(
      find.byWidgetPredicate((w) => w is SettingsToggleRow && w.label == label),
    );
    expect(row('Badges in member list').value, isFalse);
    expect(row('Sections on profiles').value, isTrue);

    row('Badges in member list').onChanged!(true);
    await tester.pump(const Duration(milliseconds: 100));

    expect(patches, [
      {'module_member_badges': true},
    ]);
    expect(row('Badges in member list').value, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  test('a settings-changed event makes a member re-read the flags', () async {
    var badges = false;
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = _container(
      (_) => {
        'name': 'slim-m',
        'protocol': 1,
        'version': '1',
        'module_member_badges': badges,
      },
      events.stream,
    );
    addTearDown(container.dispose);
    container.listen(moduleMemberBadgesShownProvider, (_, _) {});

    await container.read(moduleDisplayProvider.future);
    expect(container.read(moduleMemberBadgesShownProvider), isFalse);

    badges = true;
    events.add(const api.SpaceSettingsChanged());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await container.read(moduleDisplayProvider.future);
    expect(container.read(moduleMemberBadgesShownProvider), isTrue);
  });
}
