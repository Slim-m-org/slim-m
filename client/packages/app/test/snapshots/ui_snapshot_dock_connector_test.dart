// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A connector's Dock page sections (token shown once, "Token access", the
/// host-run panel), its consent sheet, and a Dock panel whose module failed,
/// at phone and desktop width in both themes. PNGs only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_panel_view.dart';
import 'package:slimm_app/src/features/settings/providers/dock_host_run_providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_connector_card.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_connector_consent.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_host_run_panel.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';

import '../features/modules/module_panel_fixture.dart';
import '../features/settings/home_shell_harness.dart';
import '../ui_snapshot_support.dart';

const _sizes = {'phone': Size(390, 1100), 'desktop': Size(1000, 1000)};

const _hostRun = api.HostRunAsk(
  image:
      'ghcr.io/slim-m-org/jellyfin-bridge@sha256:3f1c9a1d2b7e4c5a8d6f0e1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d',
  egress: [api.EgressHost(host: 'jellyfin.home.example', port: 8096)],
  egressPrivate: true,
  volume: true,
  memoryMib: 128,
  cpus: 0.5,
  pids: 64,
  volumeMib: 256,
);

final _manifest = api.DockManifest.fromJson({
  'id': 'jellyfin-bridge',
  'name': 'Jellyfin bridge',
  'version': '1.0.0',
  'summary': 'Plays your Jellyfin library in a call.',
  'author': 'slim-m',
  'artifact': {'kind': 'connector', 'path': 'x', 'sha256': 'a' * 64},
  'runtime': {'backend': 'connector', 'limits': <String, dynamic>{}},
  'permissions': <Object>[],
  'capabilities': <String>[],
  'extension_points': <Object>[],
  'provider': 'connector',
  'connector': {
    'permissions': Perm.sendMessages | Perm.viewChannel | Perm.speak,
    'host_run': {
      'image': _hostRun.image,
      'egress': [
        {'host': 'jellyfin.home.example', 'port': 8096},
      ],
      'egress_private': true,
      'volume': true,
    },
  },
});

final _installed = api.InstalledDockModule.fromJson({
  'id': 'jellyfin-bridge',
  'name': 'Jellyfin bridge',
  'version': '1.0.0',
  'artifact_sha256': 'a' * 64,
  'approved_capabilities': <String>[],
  'extension_points': <Object>[],
  'enabled': true,
  'installed_at': 1700000000000,
  'connector_permissions': Perm.sendMessages | Perm.viewChannel | Perm.speak,
});

Future<Widget Function(String)> _pumpPage(
  WidgetTester tester,
  Size size,
  Widget Function(String theme) page,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      connectorHostRunProvider.overrideWith(
        (ref, id) async => const api.ConnectorHostRun(
          state: api.HostRunState.crashed,
          ask: _hostRun,
          restarts: 2,
          lastError:
              'Exited with code 1: could not reach jellyfin.home.example',
        ),
      ),
      connectorHostRunLogsProvider.overrideWith(
        (ref, id) async => const [
          api.HostRunLogLine(
            ts: '10:41:02',
            stream: 'stdout',
            text: 'connected to slim-m',
          ),
          api.HostRunLogLine(
            ts: '10:41:09',
            stream: 'stderr',
            text: 'GET /Items failed: connection refused',
          ),
        ],
      ),
    ],
  );
  addTearDown(container.dispose);
  Widget build(String theme) => UncontrolledProviderScope(
    container: container,
    child: RepaintBoundary(key: snapshotBoundary, child: page(theme)),
  );
  await tester.pumpWidget(build('dark'));
  await tester.pump(const Duration(milliseconds: 400));
  return build;
}

Widget _app(String theme, Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: snapshotThemeData(theme),
  home: Scaffold(body: home),
);

void main() {
  setUpAll(loadRealFonts);

  for (final MapEntry(key: width, value: size) in _sizes.entries) {
    testWidgets('connector page sections at $width', (tester) async {
      Widget page(String theme) => _app(
        theme,
        ListView(
          padding: const EdgeInsets.all(AppSpacing.s16),
          children: [
            DockConnectorTokenReveal(
              name: 'Jellyfin bridge',
              token: 'slimm_bot_9f3c1a7d2e5b48c6a0d1e2f3a4b5c6d7',
              serverUrl: Uri.parse('https://slim.example'),
              onDismiss: () {},
            ),
            const SizedBox(height: AppSpacing.s16),
            DockConnectorCard(
              manifest: _manifest,
              installed: _installed,
              busy: false,
              onNewToken: () {},
            ),
            const SizedBox(height: AppSpacing.s16),
            DockHostRunPanel(
              moduleId: 'jellyfin-bridge',
              ask: _hostRun,
              installed: _installed,
              busy: false,
              onSetEnabled: (_) {},
            ),
          ],
        ),
      );
      final build = await _pumpPage(tester, size, page);
      await checkDarkThenLight(tester, build, (theme) async {
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, 'dock-connector-page-$width-$theme');
      });
    });

    testWidgets('connector consent sheet at $width', (tester) async {
      Widget page(String theme) => _app(
        theme,
        Builder(
          builder: (context) => Center(
            child: AppButton(
              label: 'Install',
              onPressed: () => showDockConnectorConsent(
                context,
                manifest: _manifest,
                verified: true,
                isUpdate: false,
              ),
            ),
          ),
        ),
      );
      final build = await _pumpPage(tester, size, page);
      await tester.tap(find.text('Install'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await checkDarkThenLight(tester, build, (theme) async {
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, 'dock-connector-consent-$width-$theme');
      });
    });

    testWidgets('module panel error at $width', (tester) async {
      final s = setup(
        httpClient: BoardServer(fails: true).client(),
        signedIn: true,
      );
      addTearDown(s.container.dispose);
      tester.view.physicalSize = Size(size.width == 390 ? 390 : 380, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget page(String theme) => UncontrolledProviderScope(
        container: s.container,
        child: RepaintBoundary(
          key: snapshotBoundary,
          child: _app(
            theme,
            ModulePanelView(panel: boardPanel, onClose: () {}),
          ),
        ),
      );
      await tester.pumpWidget(page('dark'));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 350));
      }
      await checkDarkThenLight(tester, page, (theme) async {
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, 'dock-panel-error-$width-$theme');
      });
    });
  }
}
