// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The network and schedule powers on the module page
/// (docs/decisions/0023-mediated-host-capabilities.md): the host list in the
/// consent sentence, the separate local network yes, and the channel a
/// schedule posts in.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/dock_host_access_card.dart';
import 'package:slimm_app/src/screens/admin/dock_module_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'dock_manifest_fixture.dart';
import 'ui_snapshot_support.dart';

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

const _hosts = ['api.example.com', 'jellyfin.lan:8096'];
const _schedules = [
  {'command': 'status', 'every_minutes': 15},
];

Map<String, dynamic> _installed({
  List<String> host = const [],
  List<String> hosts = const [],
  bool local = false,
  String? channel,
}) => {
  'id': 'ladder',
  'name': 'ladder',
  'version': '1.0.0',
  'artifact_sha256': List.filled(64, 'a').join(),
  'approved_capabilities': host,
  'approved_host_capabilities': host,
  'extension_points': <Map<String, dynamic>>[],
  'enabled': true,
  'installed_at': 1000,
  'network_hosts': hosts,
  'local_network_approved': local,
  'schedules': host.contains('schedule') ? _schedules : <Object>[],
  'schedule_channel_id': ?channel,
};

class _Harness {
  final installs = <Map<String, dynamic>>[];
  final channelPuts = <Map<String, dynamic>>[];
}

/// Opens the module page; [installed] is the row the server holds, if any.
Future<_Harness> _pump(
  WidgetTester tester, {
  required List<String> asks,
  Map<String, dynamic>? network,
  List<Map<String, dynamic>>? schedules,
  Map<String, dynamic>? installed,
  bool community = false,
  Size size = const Size(420, 1600),
}) async {
  final h = _Harness();
  var row = installed;
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/space/dock/sources') {
      return _json([
        {'id': 'official', 'repo': 'slim-m/modules', 'official': true},
        {'id': 'comm', 'repo': 'someone/mods', 'official': false},
      ]);
    }
    if (path == '/space/dock/modules') {
      return _json([
        {'id': 'ladder', 'name': 'ladder', 'version': '1.0.0', 'summary': 's'},
      ]);
    }
    if (path == '/space/dock/installed') return _json([?row]);
    if (path == '/space/dock/modules/ladder') {
      return _json(
        dockManifestJson(
          'ladder',
          '1.0.0',
          capabilities: asks,
          network: network,
          schedules: schedules,
        ),
      );
    }
    if (path == '/space/dock/modules/ladder/install') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      h.installs.add(body);
      row = _installed(
        host: (body['approved_host_capabilities'] as List).cast<String>(),
        hosts: _hosts,
        local: body['approve_local_network'] == true,
      );
      return _json(row!);
    }
    if (path == '/space/dock/modules/ladder/schedule-channel') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      h.channelPuts.add(body);
      row = {...row!, 'schedule_channel_id': ?(body['channel_id'] as String?)};
      return _json(row!);
    }
    if (path == '/channels') {
      return _json([
        {'id': 'c-gen', 'name': 'general', 'kind': 'text', 'created_at': 0},
        {'id': 'c-voice', 'name': 'lounge', 'kind': 'voice', 'created_at': 0},
        {'id': 'c-news', 'name': 'news', 'kind': 'text', 'created_at': 0},
      ]);
    }
    if (path == '/roles' || path.contains('module-permissions')) {
      return _json(<Map<String, dynamic>>[]);
    }
    throw StateError('unexpected ${request.method} $path');
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
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => DockModuleScreen(
                  moduleId: 'ladder',
                  source: community ? 'comm' : null,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Finder _toggle(String label) => find.byWidgetPredicate(
  (w) => w is AppToggle && w.semanticLabel == '$label for ladder',
);

Future<void> _flip(WidgetTester tester, String label) async {
  await tester.ensureVisible(_toggle(label));
  await tester.tap(_toggle(label));
  await tester.pumpAndSettle();
}

bool _on(WidgetTester tester, String label) =>
    tester.widget<AppToggle>(_toggle(label)).value;

/// Presses Install on the page, then the consent sheet's own Install.
Future<void> _install(WidgetTester tester) async {
  await tester.tap(find.text('Install v1.0.0'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(AppButton, 'Install'));
  await tester.pumpAndSettle();
}

const _localNetwork = {'hosts': _hosts, 'local': true};
const _lanFree = {'hosts': _hosts, 'local': false};

void main() {
  setUpAll(loadRealFonts);
  test('the net.fetch sentence names its hosts', () {
    expect(
      dockCapabilityWarning('net.fetch', details: _hosts),
      'Can send data from your server to api.example.com and '
      'jellyfin.lan:8096.',
    );
    expect(
      dockCapabilityWarning('net.fetch', details: const ['a.com']),
      'Can send data from your server to a.com.',
    );
    expect(
      dockCapabilityWarning('net.fetch', details: const ['a', 'b', 'c']),
      'Can send data from your server to a, b and c.',
    );
  });

  testWidgets('the access card shows the hosts and the schedule sentence', (
    tester,
  ) async {
    await _pump(
      tester,
      asks: ['net.fetch', 'schedule'],
      network: _lanFree,
      schedules: _schedules,
    );
    expect(find.text('Reach the internet'), findsOneWidget);
    expect(
      find.text(
        'Can send data from your server to api.example.com and '
        'jellyfin.lan:8096.',
      ),
      findsOneWidget,
    );
    expect(find.text('Run on its own'), findsOneWidget);
  });

  testWidgets('Local network shows only with network.local and net.fetch on', (
    tester,
  ) async {
    await _pump(tester, asks: ['net.fetch'], network: _localNetwork);
    expect(_toggle('Local network'), findsNothing);
    await _flip(tester, 'Reach the internet');
    expect(_toggle('Local network'), findsOneWidget);
    expect(_on(tester, 'Local network'), isFalse);
    expect(
      find.text(
        'Can also reach devices on your home network, like a NAS or media '
        'server.',
      ),
      findsOneWidget,
    );
    await _flip(tester, 'Reach the internet');
    expect(_toggle('Local network'), findsNothing);
  });

  testWidgets('a module that asks for no local network never shows it', (
    tester,
  ) async {
    await _pump(tester, asks: ['net.fetch'], network: _lanFree);
    await _flip(tester, 'Reach the internet');
    expect(_toggle('Local network'), findsNothing);
  });

  testWidgets('approve_local_network is sent false while left off', (
    tester,
  ) async {
    final h = await _pump(tester, asks: ['net.fetch'], network: _localNetwork);
    await _flip(tester, 'Reach the internet');
    await _install(tester);
    expect(h.installs.single['approve_local_network'], false);
  });

  testWidgets('approve_local_network is sent true once switched on', (
    tester,
  ) async {
    final on = await _pump(tester, asks: ['net.fetch'], network: _localNetwork);
    await _flip(tester, 'Reach the internet');
    await _flip(tester, 'Local network');
    await _install(tester);
    expect(on.installs.single['approve_local_network'], true);
    expect(on.installs.single['approved_host_capabilities'], ['net.fetch']);
  });

  testWidgets('switching net.fetch off drops the local yes', (tester) async {
    final h = await _pump(
      tester,
      asks: ['net.fetch', 'kv.store'],
      network: _localNetwork,
    );
    await _flip(tester, 'Reach the internet');
    await _flip(tester, 'Local network');
    await _flip(tester, 'Reach the internet');
    await _flip(tester, 'Remember data');
    await _install(tester);
    expect(h.installs.single['approve_local_network'], false);
    expect(h.installs.single['approved_host_capabilities'], ['kv.store']);

    await _flip(tester, 'Reach the internet');
    expect(_on(tester, 'Local network'), isFalse, reason: 'not remembered');
  });

  testWidgets('the consent sheet lists Local network as its own line', (
    tester,
  ) async {
    await _pump(
      tester,
      asks: ['net.fetch'],
      network: _localNetwork,
      community: true,
    );
    await _flip(tester, 'Reach the internet');
    await _flip(tester, 'Local network');
    await tester.tap(find.text('Install v1.0.0'));
    await tester.pumpAndSettle();
    expect(find.text('This module can:'), findsOneWidget);
    expect(find.textContaining('home network'), findsNWidgets(2));
    await writeSnapshot(tester, 'dock-consent-network-local-phone');
  });

  testWidgets('the consent sheet omits the local line while it is off', (
    tester,
  ) async {
    await _pump(
      tester,
      asks: ['net.fetch'],
      network: _localNetwork,
      community: true,
    );
    await _flip(tester, 'Reach the internet');
    await tester.tap(find.text('Install v1.0.0'));
    await tester.pumpAndSettle();
    expect(find.textContaining('home network'), findsOneWidget);
  });

  testWidgets('the consent sheet at desktop width', (tester) async {
    await _pump(
      tester,
      asks: ['net.fetch'],
      network: _localNetwork,
      community: true,
      size: const Size(1100, 900),
    );
    await _flip(tester, 'Reach the internet');
    await _flip(tester, 'Local network');
    await tester.tap(find.text('Install v1.0.0'));
    await tester.pumpAndSettle();
    await writeSnapshot(tester, 'dock-consent-network-local-desktop');
  });

  Map<String, dynamic> scheduled({String? channel}) =>
      _installed(host: ['schedule'], channel: channel);

  testWidgets('a schedule with no channel says it will not run', (
    tester,
  ) async {
    await _pump(
      tester,
      asks: ['schedule'],
      schedules: _schedules,
      installed: scheduled(),
    );
    expect(find.text('Runs status every 15 minutes'), findsOneWidget);
    expect(find.text('Posts in'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
    expect(find.textContaining('will not run'), findsOneWidget);
    await writeSnapshot(tester, 'dock-schedule-unset-phone');
  });

  testWidgets('choosing a channel calls the API and shows the result', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      asks: ['schedule'],
      schedules: _schedules,
      installed: scheduled(),
    );
    await tester.tap(find.text('Posts in'));
    await tester.pumpAndSettle();
    expect(find.text('#lounge'), findsNothing, reason: 'text channels only');
    await tester.tap(find.text('#news').last);
    await tester.pumpAndSettle();
    expect(h.channelPuts, [
      {'channel_id': 'c-news'},
    ]);
    expect(find.text('#news'), findsOneWidget);
    expect(find.textContaining('will not run'), findsNothing);
    await writeSnapshot(tester, 'dock-schedule-set-phone');
  });

  testWidgets('choosing None stops the schedule', (tester) async {
    final h = await _pump(
      tester,
      asks: ['schedule'],
      schedules: _schedules,
      installed: scheduled(channel: 'c-gen'),
    );
    expect(find.text('#general'), findsOneWidget);
    await tester.tap(find.text('Posts in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();
    expect(h.channelPuts, [
      {'channel_id': null},
    ]);
  });

  testWidgets('an unapproved schedule offers no channel', (tester) async {
    await _pump(
      tester,
      asks: ['schedule'],
      schedules: _schedules,
      installed: _installed(),
    );
    expect(find.text('Posts in'), findsNothing);
  });

  testWidgets('the module page fits a phone with every power on', (
    tester,
  ) async {
    await _pump(
      tester,
      asks: ['net.fetch', 'schedule', 'kv.store', 'message.post'],
      network: _localNetwork,
      schedules: _schedules,
      installed: _installed(
        host: ['net.fetch', 'schedule', 'kv.store', 'message.post'],
        hosts: _hosts,
        local: true,
        channel: 'c-gen',
      ),
      size: const Size(360, 800),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Local network'), findsOneWidget);
    expect(find.text('Posts in'), findsOneWidget);
  });

  testWidgets('the module page at desktop width with a schedule', (
    tester,
  ) async {
    await _pump(
      tester,
      asks: ['net.fetch', 'schedule'],
      network: _localNetwork,
      schedules: _schedules,
      installed: _installed(
        host: ['net.fetch', 'schedule'],
        hosts: _hosts,
        local: true,
        channel: 'c-gen',
      ),
      size: const Size(1100, 1300),
    );
    await writeSnapshot(tester, 'dock-schedule-desktop');
  });
}
