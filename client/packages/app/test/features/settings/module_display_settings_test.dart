// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space-wide module display switches, on the page of a module that has
/// badges or profile sections: an admin patches only the one touched, a module
/// with neither shows no switch, and every member re-reads `/version` when told.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/module_display_settings.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_display_card.dart';
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

api.InstalledDockModule _module(List<String> slotKinds) =>
    api.InstalledDockModule.fromJson({
      'id': 'xp',
      'name': 'xp',
      'version': '1.0.0',
      'artifact_sha256': 'a' * 64,
      'approved_capabilities': <String>[],
      'extension_points': <Object>[],
      'enabled': true,
      'installed_at': 1,
      'slots': [
        for (final kind in slotKinds) {'kind': kind, 'name': 'level'},
      ],
    });

const _badges = 'Show its badges in the member list';
const _sections = 'Show its sections on profiles';

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
          home: Scaffold(
            body: DockDisplayCard(
              installed: _module(['member.badge', 'profile.section']),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    SettingsToggleRow row(String label) => tester.widget<SettingsToggleRow>(
      find.byWidgetPredicate((w) => w is SettingsToggleRow && w.label == label),
    );
    expect(row(_badges).value, isFalse);
    expect(row(_sections).value, isTrue);

    row(_badges).onChanged!(true);
    await tester.pump(const Duration(milliseconds: 100));

    expect(patches, [
      {'module_member_badges': true},
    ]);
    expect(row(_badges).value, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('each switch shows only for a module that has that slot', (
    tester,
  ) async {
    final container = _container(
      (_) => {'join_policy': 'invite'},
      const Stream.empty(),
    );
    addTearDown(container.dispose);
    Future<void> show(List<String> kinds) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: DockDisplayCard(installed: _module(kinds))),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    await show(['member.badge']);
    expect(find.text(_badges), findsOneWidget);
    expect(find.text(_sections), findsNothing);

    await show(['profile.section']);
    expect(find.text(_badges), findsNothing);
    expect(find.text(_sections), findsOneWidget);

    await show(const []);
    expect(find.text('Display'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('a settings-changed event makes a member re-read the flags', () async {
    SharedPreferences.setMockInitialValues({});
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
