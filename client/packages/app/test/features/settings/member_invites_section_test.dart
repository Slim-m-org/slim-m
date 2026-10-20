// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Members can invite" switch reads `/space/settings` and patches only
/// that field.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/member_invites_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets(
    'the switch shows off and turning it on patches only that field',
    (tester) async {
      var allowed = false;
      final patches = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          patches.add(body);
          allowed = body['members_can_invite'] as bool;
        }
        return http.Response(
          jsonEncode({'join_policy': 'invite', 'members_can_invite': allowed}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
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
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: MemberInvitesSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final toggle = find.byWidgetPredicate(
        (w) => w is SettingsToggleRow && w.label == 'Members can invite',
      );
      expect(tester.widget<SettingsToggleRow>(toggle).value, isFalse);

      tester.widget<SettingsToggleRow>(toggle).onChanged!(true);
      await tester.pumpAndSettle();

      expect(patches, [
        {'members_can_invite': true},
      ]);
      expect(tester.widget<SettingsToggleRow>(toggle).value, isTrue);
    },
  );
}
