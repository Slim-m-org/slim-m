// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Resizing a window across 600 px used to replace the settings route (a
/// different page type per layout), so an open pane went back to Profile and a
/// sheet over it, such as a half-finished two-factor enrolment, was dropped.
/// The route now survives the resize, and the pane lives in the location.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/routing/settings_pages.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_harness.dart';

const _wide = Size(1280, 900);
const _phone = Size(390, 844);

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpAndSettle();
}

GoRouter _router(String start, {Widget? probe}) => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => Scaffold(
        body: TextButton(
          onPressed: () => context.push(start),
          child: const Text('open'),
        ),
      ),
    ),
    GoRoute(path: Routes.personalSettings, pageBuilder: personalSettingsPage),
    GoRoute(path: Routes.spaceSettings, pageBuilder: spaceSettingsPage),
    GoRoute(
      path: '/probe',
      pageBuilder: (context, state) => modalPage(context, probe!),
    ),
  ],
);

Future<GoRouter> _pump(
  WidgetTester tester,
  GoRouter router, {
  Size size = _wide,
  int permissions = 0,
}) async {
  GoRouter.optionURLReflectsImperativeAPIs = true;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = settingsContainer(permissions);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return router;
}

String _location(GoRouter router) =>
    router.routeInformationProvider.value.uri.toString();

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          onPressed: () => setState(() => taps++),
          child: Text('taps $taps'),
        ),
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(content: Text('half done')),
          ),
          child: const Text('start'),
        ),
      ],
    ),
  );
}

class _PaneProbe extends _Probe {
  const _PaneProbe();

  @override
  State<_Probe> createState() => _PaneProbeState();
}

class _PaneProbeState extends _ProbeState {
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('taps $taps'),
  );
}

void main() {
  testWidgets('a screen and the sheet over it survive a resize across 600', (
    tester,
  ) async {
    await _pump(tester, _router('/probe', probe: const _Probe()));
    await tester.tap(find.text('taps 0'));
    await tester.pump();
    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    expect(find.text('half done'), findsOneWidget);

    await _resize(tester, _phone);
    expect(find.text('taps 1'), findsOneWidget);
    expect(find.text('half done'), findsOneWidget);

    await _resize(tester, _wide);
    expect(find.text('taps 1'), findsOneWidget);
    expect(find.text('half done'), findsOneWidget);
  });

  testWidgets('the open settings pane survives the resize and is in the URL', (
    tester,
  ) async {
    final router = await _pump(tester, _router(Routes.personalSettings));
    await tester.tap(find.text('Account & devices'));
    await tester.pumpAndSettle();
    expect(_location(router), Routes.personalSettingsPane(accountDevicesPane));
    expect(find.text('Delete account...'), findsOneWidget);

    await _resize(tester, _phone);
    expect(find.text('Delete account...'), findsOneWidget);

    await _resize(tester, _wide);
    expect(find.text('Delete account...'), findsOneWidget);
    expect(_location(router), Routes.personalSettingsPane(accountDevicesPane));
  });

  testWidgets('a pane link opens that pane from cold', (tester) async {
    await _pump(
      tester,
      _router(Routes.personalSettingsPane(accountDevicesPane)),
    );

    expect(find.text('Delete account...'), findsOneWidget);
  });

  testWidgets('Space settings carries its pane in the location too', (
    tester,
  ) async {
    final router = await _pump(
      tester,
      _router(Routes.spaceSettings),
      permissions: allPermissionBits,
    );
    await tester.tap(find.text('Invites'));
    await tester.pumpAndSettle();

    expect(_location(router), Routes.spaceSettingsPane('invites'));
  });

  testWidgets('a pane keeps its own state across the two-pane breakpoint', (
    tester,
  ) async {
    tester.view.physicalSize = _wide;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: SettingsPanesScaffold(
          title: 'Settings',
          backTooltip: 'Back',
          backFallback: '/',
          groups: [
            SettingsPaneGroup(
              label: 'You',
              panes: [
                SettingsPane(
                  id: 'one',
                  label: 'One',
                  builder: (_) => const _PaneProbe(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('One').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('taps 0'));
    await tester.pump();

    await _resize(tester, const Size(700, 900));
    expect(find.text('taps 1'), findsOneWidget);

    await _resize(tester, _wide);
    expect(find.text('taps 1'), findsOneWidget);
  });
}
