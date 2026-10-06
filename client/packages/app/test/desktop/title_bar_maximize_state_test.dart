// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The title bar maximize icon follows every way the window can maximize.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/title_bar.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/fake_desktop_window_port.dart';

/// A host matching real usage: [TitleBar] sits atop the rest of the app
/// inside a fixed-height slot, the same shape `DesktopChrome`'s own
/// `Column` gives it, so a tap or drag lands where it really would - and
/// the real `AppTokens` theme, since [AppIconButton] reads it unconditionally.
/// [TitleBar] reads `serverInfoProvider`/`syncControllerProvider` now, so
/// this needs the same minimal `apiProvider`/`keyStoreProvider` overrides
/// every other suite hitting a real `SlimmApi` gives it, rather than
/// constructing one against an unconfigured session.
Future<SemanticsHandle> _pump(
  WidgetTester tester, {
  required FakeDesktopWindowPort port,
  required DesktopPlatform platform,
  required Future<void> Function() onRequestClose,
}) async {
  final handle = tester.ensureSemantics();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((_) async => http.Response('', 404)),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Column(
            children: [
              TitleBar(
                port: port,
                platform: platform,
                onRequestClose: onRequestClose,
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    ),
  );
  return handle;
}

void main() {
  testWidgets('double-click maximize flips the middle button to Restore', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    final handle = await _pump(
      tester,
      port: port,
      platform: DesktopPlatform.linux,
      onRequestClose: () async {},
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Maximize'), findsOneWidget);

    final region = find.byType(TitleBar);
    await tester.tap(region);
    await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 10));
    await tester.tap(region);
    await tester.pumpAndSettle();

    expect(port.maximizeCalls, 1);
    expect(find.bySemanticsLabel('Restore'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a WM-driven maximize flips the middle button to Restore', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    final handle = await _pump(
      tester,
      port: port,
      platform: DesktopPlatform.linux,
      onRequestClose: () async {},
    );
    await tester.pumpAndSettle();

    port.maximized = true;
    port.emit(DesktopWindowEventKind.maximize);
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Restore'), findsOneWidget);
    handle.dispose();
  });
}
