// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify rows of Connections, driven by the real linker and the real
/// redirect handler: each state appears in place on the Spotify row, the
/// show-my-track switch exists only while linked, an error is a persistent
/// `AppErrorState` with Retry, and Unlink works (decision 0056). Pictures are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/linked_accounts.dart';
import 'package:slimm_app/src/features/settings/widgets/connections_section.dart';
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
  final rig = SpotifyRig(
    overrides: [
      myLinkedAccountsProvider.overrideWith(
        (ref) async => <api.LinkedAccount>[],
      ),
    ],
  );
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
              child: ConnectionsSection(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return rig;
}

/// Spotify is the card's last row, so its button is the last with that label.
Finder _spotifyButton(String label) => find.text(label).last;

Future<void> _shot(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the show-track text lines up with the Spotify title', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      window: const Size(390, 844),
      brightness: Brightness.light,
    );
    await tester.tap(_spotifyButton('Link'));
    await _settle(tester);
    await tester.runAsync(() => rig.linker.handleCallback(rig.redirect()));
    await _settle(tester);

    final title = tester.getTopLeft(find.text('Spotify')).dx;
    expect(tester.getTopLeft(find.text('Show my Spotify track')).dx, title);
    expect(tester.getTopLeft(find.text('Discord')).dx, title);
  });

  testWidgets('a long account name stays on one line', (tester) async {
    final rig = await _pump(
      tester,
      window: const Size(390, 844),
      brightness: Brightness.light,
    );
    const name =
        'An extremely long Spotify display name that cannot possibly '
        'fit beside the unlink button on a phone';
    rig.profile = () => http.Response('{"display_name":"$name"}', 200);
    await tester.tap(_spotifyButton('Link'));
    await _settle(tester);
    await tester.runAsync(() => rig.linker.handleCallback(rig.redirect()));
    await _settle(tester);

    final height = tester.getSize(find.text(name)).height;
    expect(height, lessThan(AppText.caption.fontSize! * 2));
  });

  final cases = [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1280, 800)),
  ];
  for (final (label, window) in cases) {
    for (final brightness in Brightness.values) {
      final suffix = '$label-${brightness.name}';

      testWidgets('$suffix: from Link to linked, in place', (tester) async {
        final rig = await _pump(tester, window: window, brightness: brightness);
        expect(find.text('Spotify'), findsOne);
        expect(find.text('Not linked'), findsWidgets);
        expect(find.byType(AppToggle), findsNothing);
        await _shot(tester, 'spotify-row-off-$suffix');

        await tester.tap(_spotifyButton('Link'));
        await _settle(tester);
        expect(find.textContaining('Finish signing in'), findsOne);
        expect(find.text('Cancel'), findsOne);
        expect(find.byType(AppToggle), findsNothing);
        await _shot(tester, 'spotify-row-waiting-$suffix');

        await tester.runAsync(() => rig.linker.handleCallback(rig.redirect()));
        await _settle(tester);
        expect(find.text('Nick'), findsOne);
        expect(find.text('Show my Spotify track'), findsOne);
        expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isTrue);
        await _shot(tester, 'spotify-row-connected-$suffix');

        await tester.tap(find.byType(AppToggle));
        await _settle(tester);
        expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isFalse);
        expect(find.text('Unlink'), findsWidgets, reason: 'still linked');

        await tester.tap(_spotifyButton('Unlink'));
        await _settle(tester);
        expect(find.byType(AppToggle), findsNothing);
        expect(find.text('Nick'), findsNothing);
      });

      testWidgets('$suffix: a failure stays, with Retry and Dismiss', (
        tester,
      ) async {
        final rig = await _pump(tester, window: window, brightness: brightness);
        await tester.tap(_spotifyButton('Link'));
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
        expect(find.textContaining('Finish signing in'), findsOne);

        await tester.tap(find.text('Cancel'));
        await _settle(tester);
        expect(find.textContaining('Waiting'), findsNothing);
      });
    }
  }
}
