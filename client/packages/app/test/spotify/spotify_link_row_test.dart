// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify row in Settings at phone width, driven by the real switch and
/// the real redirect handler: each state appears in place under the switch,
/// an error is a persistent `AppErrorState` with Retry, and Disconnect works
/// (decision 0056). Pictures are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/activity_sharing_section.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'spotify_rig.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
  await tester.pump();
}

Future<SpotifyRig> _pump(
  WidgetTester tester, {
  required Size window,
  required Brightness brightness,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rig = SpotifyRig();
  addTearDown(() => tester.runAsync(rig.dispose));
  await tester.runAsync(rig.start);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: rig.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness,
            brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(AppSpacing.s16),
              child: ActivitySharingSection(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return rig;
}

Future<void> _shot(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
}

void main() {
  setUpAll(loadRealFonts);

  final cases = [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1280, 800)),
  ];
  for (final (label, window) in cases) {
    for (final brightness in Brightness.values) {
      final suffix = '$label-${brightness.name}';

      testWidgets('$suffix: from switch to connected, in place', (
        tester,
      ) async {
        final rig = await _pump(tester, window: window, brightness: brightness);
        expect(find.text('Show my Spotify track'), findsOne);
        expect(find.textContaining('Waiting'), findsNothing);
        await _shot(tester, 'spotify-row-off-$suffix');

        await tester.tap(find.byType(AppToggle));
        await _settle(tester);
        expect(find.textContaining('Waiting for Spotify'), findsOne);
        expect(find.text('Cancel'), findsOne);
        expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isFalse);
        await _shot(tester, 'spotify-row-waiting-$suffix');

        await tester.runAsync(() => rig.linker.handleCallback(rig.redirect()));
        await _settle(tester);
        expect(find.text('Connected as Nick'), findsOne);
        expect(find.text('Disconnect'), findsOne);
        expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isTrue);
        await _shot(tester, 'spotify-row-connected-$suffix');

        await tester.tap(find.text('Disconnect'));
        await _settle(tester);
        expect(find.textContaining('Connected'), findsNothing);
        expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isFalse);
      });

      testWidgets('$suffix: a failure stays, with Retry and Dismiss', (
        tester,
      ) async {
        final rig = await _pump(tester, window: window, brightness: brightness);
        await tester.tap(find.byType(AppToggle));
        await _settle(tester);
        await tester.runAsync(
          () => rig.linker.handleCallback(
            rig.redirect(code: null, error: 'access_denied'),
          ),
        );
        await _settle(tester);

        expect(find.byType(AppErrorState), findsOne);
        expect(find.textContaining('declined'), findsOne);
        expect(find.byType(SnackBar), findsNothing);
        await _shot(tester, 'spotify-row-error-$suffix');

        await tester.tap(find.text('Retry'));
        await _settle(tester);
        expect(rig.launched, hasLength(2));
        expect(find.byType(AppErrorState), findsNothing);
        expect(find.textContaining('Waiting for Spotify'), findsOne);

        await tester.tap(find.text('Cancel'));
        await _settle(tester);
        expect(find.textContaining('Waiting'), findsNothing);
      });
    }
  }
}
