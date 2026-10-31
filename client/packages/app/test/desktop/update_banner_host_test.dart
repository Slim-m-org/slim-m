// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [UpdateBannerHost], the reason a phone sees the update banner at all.
///
/// The banner's own file is mounted in `DesktopChrome`, outside the router,
/// so before this wrapper existed a mobile build polled for nothing: no
/// surface ever read [inSessionUpdateProvider]. These tests are about the
/// mounting decision rather than the banner's content, which
/// `desktop/update_available_banner_test.dart` covers.
///
/// The geometry checks below are the actual regression: a `SafeArea` insets
/// by adding padding around its child whatever that child's own size is, so
/// wrapping an empty banner in one the whole time reserved a full
/// status-bar-height band of nothing above the rail on every phone - "costs
/// nothing but the child" was true of the widget tree but not of the screen,
/// and a check that only asked whether `AppCallout` was present passed
/// against that exact mistake.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/widgets/update_banner_host.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _update = ClientUpdate(
  version: '9.9.9',
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.unknown,
);

/// An iPhone's own notch inset, matching `rail_safe_area_test.dart`.
const double _topInset = 59;

Future<void> _pump(
  WidgetTester tester, {
  required bool ownsBanner,
  ClientUpdate? update,
  double topInset = 0,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.padding = FakeViewPadding(top: topInset);
  tester.view.viewPadding = FakeViewPadding(top: topInset);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inSessionUpdateProvider.overrideWith((ref) => update),
        // No real Timer: this file is about where the banner mounts.
        updateWatcherProvider.overrideWith(
          (ref) => UpdateWatcher(ref, shouldRun: () => false),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: UpdateBannerHost(
          ownsBanner: ownsBanner,
          child: const Scaffold(body: Text('the app')),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a layout with no outer chrome shows the banner itself', (
    tester,
  ) async {
    await _pump(tester, ownsBanner: false, update: _update);

    expect(find.byType(AppCallout), findsOneWidget);
    expect(find.textContaining('9.9.9'), findsOneWidget);
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('desktop chrome already has one, so this mounts no second', (
    tester,
  ) async {
    await _pump(tester, ownsBanner: true, update: _update);

    expect(
      find.byType(AppCallout),
      findsNothing,
      reason:
          'DesktopChrome mounts the banner outside the router; two banners '
          'saying the same thing is worse than none',
    );
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('costs nothing but the child while no update has been found', (
    tester,
  ) async {
    await _pump(tester, ownsBanner: false);

    expect(find.byType(AppCallout), findsNothing);
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets(
    'reserves no dead band above the child on a notched phone with no '
    'update to show',
    (tester) async {
      await _pump(tester, ownsBanner: false, topInset: _topInset);

      expect(
        tester.getRect(find.text('the app')).top,
        0.0,
        reason:
            'nothing is showing, so the host must hand the child straight '
            "back rather than reserving the banner's own status-bar inset "
            'above it',
      );
    },
  );

  testWidgets(
    "does not inset the child a second time below a banner that's really "
    'showing',
    (tester) async {
      await _pump(
        tester,
        ownsBanner: false,
        update: _update,
        topInset: _topInset,
      );

      final bannerBottom = tester.getRect(find.byType(AppCallout)).bottom;
      expect(
        tester.getRect(find.text('the app')).top,
        bannerBottom,
        reason:
            "the banner's own SafeArea already spent the top inset; the "
            'child must start right where the banner ends, not one more '
            'inset below it',
      );
    },
  );
}
