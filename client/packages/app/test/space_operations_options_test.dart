// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Options of the Space settings Operations panes that no other test drives:
/// every message retention value, the noise suppression default turned off,
/// analytics turned off, the storage and metrics refresh buttons, and the
/// MANAGE_SERVER gate on the four panes.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/analytics_screen.dart';
import 'package:slimm_app/src/screens/admin/performance_screen.dart';
import 'package:slimm_app/src/screens/admin/server_metrics_screen.dart';
import 'package:slimm_app/src/screens/admin/space_voice_screen.dart';
import 'package:slimm_app/src/screens/admin/storage_screen.dart';
import 'package:slimm_app/src/screens/space_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

typedef _Handler = http.Response Function(http.Request request);

List<Override> _overrides(_Handler handler, {int? permissions}) => [
  keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
  sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
  if (permissions != null) myPermissionsProvider.overrideWithValue(permissions),
  if (permissions != null)
    myVisibleChannelsProvider.overrideWith((ref) async => const []),
  apiProvider.overrideWith((ref) {
    final built = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: MockClient((request) async => handler(request)),
    );
    ref.onDispose(built.close);
    return built;
  }),
];

Future<void> _pump(WidgetTester tester, Widget screen, _Handler handler) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(handler),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: SingleChildScrollView(child: screen)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _body(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

void main() {
  testWidgets('every retention window sends its day count, and only a '
      'shorter or first window asks to confirm', (tester) async {
    var days = 0;
    final patched = <int>[];
    await _pump(tester, const PerformancePane(), (r) {
      switch (r.url.path) {
        case '/space/retention/preview':
          return _json({'retention_days': 30, 'messages': 12});
        case '/space/retention':
          if (r.method == 'PATCH') {
            days = _body(r)['retention_days'] as int;
            patched.add(days);
          }
          return _json({'retention_days': days});
        case '/space/canvas-cap':
          return _json({'object_cap': 20000});
        case '/space/screen-share':
          return _json({'max_height': 2160});
      }
      return _json({'enabled': false});
    });

    Future<void> choose(String label, {bool confirms = false}) async {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        find.text('Delete old messages'),
        confirms ? findsOneWidget : findsNothing,
        reason: label,
      );
      if (confirms) {
        await tester.tap(find.text('Delete old messages'));
        await tester.pumpAndSettle();
      }
    }

    await choose('30 days', confirms: true);
    await choose('90 days');
    await choose('365 days');
    await choose('90 days', confirms: true);
    await choose('Never');

    expect(patched, [30, 90, 365, 90, 0]);
  });

  testWidgets('turning strong noise suppression off patches false', (
    tester,
  ) async {
    final patches = <Map<String, dynamic>>[];
    await _pump(tester, const SpaceVoicePane(), (r) {
      if (r.url.path == '/space/settings') {
        if (r.method == 'PATCH') patches.add(_body(r));
        return _json({
          'join_policy': 'invite',
          'strong_noise_suppression': patches.isEmpty,
        });
      }
      if (r.url.path == '/space/retention') return _json({'retention_days': 0});
      if (r.url.path == '/space/canvas-cap') return _json({'object_cap': 5000});
      if (r.url.path == '/space/screen-share') {
        return _json({'max_height': 1080});
      }
      return _json({'enabled': false});
    });

    final toggle = find.bySemanticsLabel('Strong noise suppression by default');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(patches, [
      {'strong_noise_suppression': false},
    ]);
  });

  testWidgets('turning analytics off sends enabled: false', (tester) async {
    var enabled = true;
    final patched = <bool>[];
    await _pump(tester, const AnalyticsPane(), (r) {
      if (r.method == 'PATCH') {
        enabled = _body(r)['enabled'] as bool;
        patched.add(enabled);
      }
      return _json(
        enabled
            ? {
                'enabled': true,
                'stats': {
                  'total_messages': 1,
                  'member_count': 1,
                  'channel_count': 1,
                  'attachment_bytes': 0,
                  'messages_by_day': <Object>[],
                  'active_hours': List.filled(24, 0),
                  'memory_samples': <Object>[],
                },
              }
            : {'enabled': false},
      );
    });

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();

    expect(patched, [false]);
    expect(find.text('Record Space analytics'), findsOneWidget);
  });

  testWidgets('the storage refresh button fetches usage again', (tester) async {
    var fetches = 0;
    await _pump(tester, const StoragePane(), (r) {
      fetches++;
      return _json({
        'database_bytes': 1000,
        'database_reclaimable_bytes': 0,
        'attachment_bytes': 0,
        'top_channels': <Object>[],
        'sweeps': <Object>[],
      });
    });
    expect(fetches, 1);

    await tester.tap(find.byTooltip('Refresh storage usage'));
    await tester.pumpAndSettle();

    expect(fetches, 2);
  });

  testWidgets('the server metrics refresh button scrapes again', (
    tester,
  ) async {
    var scrapes = 0;
    await _pump(tester, const ServerMetricsPane(), (r) {
      scrapes++;
      return http.Response('', 200);
    });
    expect(scrapes, 1);

    await tester.tap(find.byTooltip('Refresh server metrics'));
    await tester.pumpAndSettle();

    expect(scrapes, 2);
  });

  group('the Operations group is gated on MANAGE_SERVER', () {
    Future<void> openSettings(WidgetTester tester, int permissions) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(
            (r) => http.Response('[]', 200),
            permissions: permissions,
          ),
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: const SpaceSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('without it none of the four panes is offered', (tester) async {
      await openSettings(tester, Perm.manageRoles);

      expect(
        find.text(ActionLabels.operationsGroup.toUpperCase()),
        findsNothing,
      );
      for (final label in [
        ActionLabels.retentionAndLimits,
        'Analytics',
        'Storage',
        'Server metrics',
      ]) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('with it each opens its own pane', (tester) async {
      await openSettings(tester, Perm.manageServer);

      final panes = <String, Type>{
        ActionLabels.retentionAndLimits: PerformancePane,
        'Analytics': AnalyticsPane,
        'Storage': StoragePane,
        'Server metrics': ServerMetricsPane,
      };
      for (final entry in panes.entries) {
        await tester.tap(find.text(entry.key).first);
        await tester.pumpAndSettle();
        expect(
          find.byType(entry.value),
          findsOneWidget,
          reason: '${entry.key} pane',
        );
      }
    });
  });
}
