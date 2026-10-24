// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Settings card on a module's Dock page: loaded when the page opens,
/// hidden when the module declares none, and a failure stays on the card.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_view.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_settings_card.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../dock_manifest_fixture.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _setting(Object? value) => {
  'settings': [
    {'key': 'name', 'type': 'string', 'label': 'Display name', 'value': value},
  ],
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

final _installed = api.InstalledDockModule(
  id: 'xp',
  name: 'xp',
  version: '1.0.0',
  artifactSha256: 'a' * 64,
  approvedCapabilities: const [],
  extensionPoints: const [],
  enabled: true,
  installedAt: 1,
  declaresSettings: true,
);

Future<void> _pump(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) handler, {
  Widget Function()? child,
}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(handler),
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: child?.call() ?? const DockSettingsCard(moduleId: 'xp'),
          ),
        ),
      ),
    ),
  );
}

Finder _name() => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is AppInput && w.semanticLabel == 'Display name',
  ),
  matching: find.byType(EditableText),
);

void main() {
  testWidgets('it shows a spinner while the settings load', (tester) async {
    final gate = Completer<http.Response>();
    await _pump(tester, (_) => gate.future);
    await tester.pump();
    expect(find.byType(AppSpinner), findsOneWidget);
    gate.complete(_json(_setting('x')));
    await tester.pumpAndSettle();
    expect(find.byType(AppSpinner), findsNothing);
    expect(find.text('Display name'), findsWidgets);
  });

  testWidgets('a module with no settings shows nothing', (tester) async {
    await _pump(tester, (_) async => _json({'settings': <Object>[]}));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(find.byType(AppInput), findsNothing);
  });

  testWidgets('a load failure is an error state with Retry, not a snackbar', (
    tester,
  ) async {
    var calls = 0;
    await _pump(tester, (_) async {
      calls++;
      return calls == 1 ? _json({'error': 'down'}, 500) : _json(_setting('x'));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorState), findsNothing);
    expect(find.text('Display name'), findsWidgets);
  });

  testWidgets('a failed save shows the error and keeps the edit', (
    tester,
  ) async {
    await _pump(tester, (request) async {
      if (request.method == 'PUT') return _json({'error': 'no'}, 422);
      return _json(_setting('x'));
    });
    await tester.pumpAndSettle();
    await tester.enterText(_name(), 'Bob');
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.widget<EditableText>(_name()).controller.text, 'Bob');
    expect(find.text('Save changes'), findsOneWidget);
  });

  testWidgets('a save sends only the change and shows the saved settings', (
    tester,
  ) async {
    Object? body;
    await _pump(tester, (request) async {
      if (request.method == 'PUT') {
        body = jsonDecode(request.body);
        return _json(_setting('Bob'));
      }
      return _json(_setting('x'));
    });
    await tester.pumpAndSettle();
    await tester.enterText(_name(), 'Bob');
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(body, {
      'values': {'name': 'Bob'},
    });
    expect(find.text('Save changes'), findsNothing);
    expect(tester.widget<EditableText>(_name()).controller.text, 'Bob');
  });

  testWidgets('the module page has the card only for a module with settings', (
    tester,
  ) async {
    Widget view(api.InstalledDockModule installed) => DockManifestView(
      manifest: api.DockManifest.fromJson(dockManifestJson('xp', '1.0.0')),
      installed: installed,
      busy: false,
      error: null,
      onErrorDismiss: () {},
      onInstall: () {},
      onSetEnabled: (_) {},
      onUninstall: () {},
      onChooseAccess: () {},
      approvedHostCapabilities: const {},
      onToggleHostCapability: (_, _) {},
    );
    await _pump(
      tester,
      (_) async => _json(_setting('x')),
      child: () => view(_installed),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DockSettingsCard), findsOneWidget);

    final none = api.InstalledDockModule.fromJson({
      'id': 'xp',
      'name': 'xp',
      'version': '1.0.0',
      'artifact_sha256': 'a' * 64,
      'approved_capabilities': <String>[],
      'extension_points': <Object>[],
      'enabled': true,
      'installed_at': 1,
    });
    await _pump(
      tester,
      (_) async => _json(_setting('x')),
      child: () => view(none),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DockSettingsCard), findsNothing);
  });
}
