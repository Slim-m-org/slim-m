// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Hide bots" switch on the Bots pane reads `/space/settings`, patches
/// only that field, and tells this client's own roster at once.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/roster_grouping.dart';
import 'package:slimm_app/src/features/settings/providers/space_settings.dart';
import 'package:slimm_app/src/features/settings/screens/admin/bots_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Space {
  _Space({required this.hidden});

  bool hidden;
  final patches = <Map<String, dynamic>>[];
  var versionFetches = 0;

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'PATCH' && path == '/space/settings') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      patches.add(body);
      hidden = body['hide_bots_in_member_list'] as bool;
    }
    return switch (path) {
      '/space/settings' => _json({
        'join_policy': 'invite',
        'hide_bots_in_member_list': hidden,
      }),
      '/version' => _json({
        'name': 'slim-m',
        'version': '1.0.0',
        'protocol': 1,
        'hide_bots_in_member_list': hidden,
      }, onServe: () => versionFetches += 1),
      _ => http.Response('[]', 200),
    };
  }
}

http.Response _json(Map<String, dynamic> body, {void Function()? onServe}) {
  onServe?.call();
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Future<ProviderContainer> _pumpBotsPane(
  WidgetTester tester,
  _Space space,
) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      myPermissionsProvider.overrideWithValue(Perm.manageServer),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride(space.answer),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const BotsScreen(),
      ),
    ),
  );
  await waitUntil(
    tester,
    () => container.read(spaceSettingsProvider).hasValue,
    reason: 'the Space settings never loaded',
  );
  return container;
}

Finder get _toggle => find.byWidgetPredicate(
  (w) => w is SettingsToggleRow && w.label == 'Hide bots',
);

void main() {
  testWidgets('the switch shows bots listed, and turning it on patches only '
      'that field and refreshes this client', (tester) async {
    final space = _Space(hidden: false);
    final container = await _pumpBotsPane(tester, space);
    container.listen(hideBotsInMemberListProvider, (_, _) {});
    await waitUntil(tester, () => space.versionFetches == 1);
    expect(tester.widget<SettingsToggleRow>(_toggle).value, isFalse);
    expect(container.read(hideBotsInMemberListProvider), isFalse);

    tester.widget<SettingsToggleRow>(_toggle).onChanged!(true);
    await waitUntil(
      tester,
      () => container.read(hideBotsInMemberListProvider),
      reason: 'this client never re-read /version',
    );

    expect(space.patches, [
      {'hide_bots_in_member_list': true},
    ]);
    expect(tester.widget<SettingsToggleRow>(_toggle).value, isTrue);
  });

  testWidgets('the switch opens on when the Space already hides bots', (
    tester,
  ) async {
    await _pumpBotsPane(tester, _Space(hidden: true));

    expect(tester.widget<SettingsToggleRow>(_toggle).value, isTrue);
  });
}
