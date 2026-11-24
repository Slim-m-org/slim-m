// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Manage sources" sheet when the catalog did not load, and while a removal is under way.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_manage_sources.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _acme = api.DockSource(id: 's1', repo: 'acme/mods', official: false);

Future<void> _open(
  WidgetTester tester,
  Future<DockCatalog> Function() catalog, {
  Future<http.Response> Function(http.Request)? upstream,
}) async {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride(upstream ?? (request) async => http.Response('', 204)),
      dockCatalogProvider.overrideWith((ref) => catalog()),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(showManageDockSourcesSheet(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await pumpFrames(tester);
}

void main() {
  testWidgets(
    'a catalog that failed is an error with a retry, not "none yet"',
    (tester) async {
      await _open(tester, () async => throw http.ClientException('down'));
      expect(find.text('No community sources yet.'), findsNothing);
      expect(
        find.text('Could not load the community sources.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets('Remove waits while a removal is under way', (tester) async {
    final deleting = Completer<http.Response>();
    await _open(
      tester,
      () async => const DockCatalog(
        entries: [],
        installed: [],
        sections: [DockSourceSection(source: _acme, entries: [])],
      ),
      upstream: (request) => deleting.future,
    );
    await tester.tap(find.bySemanticsLabel('Remove source acme/mods'));
    await pumpFrames(tester);
    await tester.tap(find.text('Remove source').last);
    await tester.pump();

    final remove = tester.widget<AppButton>(
      find.byWidgetPredicate((w) => w is AppButton && w.label == 'Remove'),
    );
    expect(remove.onPressed, isNull);
    deleting.complete(http.Response(jsonEncode({}), 204));
    await pumpFrames(tester);
  });
}
