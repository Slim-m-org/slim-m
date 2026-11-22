// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock panel's entry (decision 0132): the apps sheet lists the panels a
/// viewer may open, a press docks one on a wide window and opens its own page
/// full screen on a phone, and that page comes back to the same scene.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/app_launch.dart';
import 'package:slimm_app/src/features/modules/providers/module_panels.dart';
import 'package:slimm_app/src/features/modules/screens/module_panel_screen.dart';
import 'package:slimm_app/src/features/modules/widgets/app_launcher_sheet.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';

import '../settings/home_shell_harness.dart';
import 'module_panel_fixture.dart';

const _app = api.App(moduleId: 'dice', command: 'roll', name: 'Dice');

Future<ProviderContainer> _pump(
  WidgetTester tester,
  double width, {
  BoardServer? server,
  List<api.App> apps = const [],
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = setup(
    httpClient: (server ?? BoardServer()).client(),
    signedIn: true,
    extraOverrides: [appLaunchProvider.overrideWith((ref) async => apps)],
  );
  addTearDown(() => teardown(tester, s.container, s.db));
  final router = GoRouter(
    initialLocation: '/channels/c1',
    routes: [
      GoRoute(
        path: '/channels/:id',
        builder: (context, state) => Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showAppLauncherSheet(context, ref, 'c1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: Routes.modulePanelPattern,
        builder: (context, state) => ModulePanelScreen(
          moduleId: state.pathParameters['moduleId']!,
          command: state.pathParameters['command']!,
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: s.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  return s.container;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

void main() {
  testWidgets('the apps sheet lists a panel under its own label', (
    tester,
  ) async {
    await _pump(tester, 1280, apps: const [_app]);
    expect(find.text('Dice'), findsOneWidget);
    expect(find.text('Panels'), findsOneWidget);
    expect(find.text('Board'), findsOneWidget);
  });

  testWidgets('with no apps, the panel is listed without a label', (
    tester,
  ) async {
    await _pump(tester, 1280);
    expect(find.text('Board'), findsOneWidget);
    expect(find.text('Panels'), findsNothing);
    expect(find.textContaining('No apps installed'), findsNothing);
  });

  testWidgets('at 1280 a press docks the panel rather than opening a page', (
    tester,
  ) async {
    final container = await _pump(tester, 1280);
    await tester.tap(find.text('Board'));
    await _settle(tester);
    expect(container.read(openModulePanelProvider)?.key, boardPanel.key);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets(
    'at 390 a press opens the panel full screen, and it comes back to its scene',
    (tester) async {
      final server = BoardServer();
      final container = await _pump(tester, 390, server: server);
      await tester.tap(find.text('Board'));
      await _settle(tester);
      expect(container.read(openModulePanelProvider), isNull);
      expect(find.text('Count 0'), findsOneWidget);
      final header = tester.getRect(find.bySemanticsLabel('Close Board'));
      expect(header.right, lessThanOrEqualTo(390));
      expect(header.right, greaterThan(390 - 60));

      await tester.tap(find.bySemanticsLabel('Step forward'));
      await _settle(tester);
      await tester.tap(find.bySemanticsLabel('Close Board'));
      await _settle(tester);
      expect(find.text('open'), findsOneWidget);

      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.tap(find.text('Board'));
      await _settle(tester);
      expect(find.text('Count 1'), findsOneWidget);
      expect(server.firstRuns, 1);
    },
  );

  testWidgets('a scene that asks to be redrawn is, while the panel is open', (
    tester,
  ) async {
    final server = BoardServer(refreshMs: 500);
    await _pump(tester, 390, server: server);
    await tester.tap(find.text('Board'));
    await _settle(tester);
    final before = server.inputs.length;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final redraws = server.inputs.skip(before);
    expect(redraws, isNotEmpty, reason: 'clamped to 2 s, so one redraw');
    expect(redraws.first, '{"action":"refresh","state":"0"}');

    await tester.tap(find.bySemanticsLabel('Close Board'));
    await _settle(tester);
    final closed = server.inputs.length;
    await tester.pump(const Duration(seconds: 6));
    expect(server.inputs.length, closed, reason: 'a closed panel never runs');
  });
}
