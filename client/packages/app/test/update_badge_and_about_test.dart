// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two quiet places a pending update shows up once the banner is gone:
/// a dot on the rail's gear, and the About pane.
///
/// The banner was the only sign a new version existed, and it is dismissible.
/// Dismissing it used to clear the fact along with the notice, so the only way
/// back to it was relaunching into the splash check. The badge and the About
/// row are that fact surviving; these tests pin the surviving part, because a
/// badge that vanishes with the banner is the exact bug this closes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/update_status_rows.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _update = ClientUpdate(
  version: '0.79.0',
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.tarball,
);

Widget _hosting(Widget child, List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: child),
  ),
);

Finder _gearDot() => find.byKey(updateBadgeDotKey);

Override _appInfo() => appInfoProvider.overrideWith(
  (ref) => Future.value(
    PackageInfo(
      appName: 'slim-m',
      packageName: 'top.npcserver.slimm',
      version: '0.78.0',
      buildNumber: '1',
    ),
  ),
);

void main() {
  group('the rail gear badge', () {
    testWidgets('is absent while nothing is waiting', (tester) async {
      await tester.pumpWidget(
        _hosting(Builder(builder: railSettingsButton), const []),
      );

      expect(find.bySemanticsLabel('Personal settings'), findsOneWidget);
      expect(_gearDot(), findsNothing);
    });

    testWidgets('appears, and says so in the label, once one is found', (
      tester,
    ) async {
      await tester.pumpWidget(
        _hosting(Builder(builder: railSettingsButton), [
          inSessionUpdateProvider.overrideWith((ref) => _update),
        ]),
      );

      expect(
        find.bySemanticsLabel('Personal settings, an update is available'),
        findsOneWidget,
        reason: 'a dot alone tells a screen reader nothing',
      );
      expect(_gearDot(), findsOneWidget);
    });

    testWidgets('survives the banner being dismissed', (tester) async {
      // The state a dismissal leaves: update known, banner suppressed.
      await tester.pumpWidget(
        _hosting(Builder(builder: railSettingsButton), [
          inSessionUpdateProvider.overrideWith((ref) => _update),
          dismissedBannerVersionProvider.overrideWith((ref) => '0.79.0'),
        ]),
      );

      expect(
        _gearDot(),
        findsOneWidget,
        reason: 'waving the banner away is not the same as being up to date',
      );
    });
  });

  group('the About pane', () {
    testWidgets('shows both versions, so a screenshot can be triaged', (
      tester,
    ) async {
      await tester.pumpWidget(
        _hosting(
          UpdateStatusRows(
            check: ({client, required currentVersion, format}) async => _update,
            shouldRun: () => true,
          ),
          [inSessionUpdateProvider.overrideWith((ref) => _update), _appInfo()],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('0.79.0 is available. You have '),
        findsOneWidget,
      );
    });

    testWidgets('the manual check reports finding nothing', (tester) async {
      await tester.pumpWidget(
        _hosting(
          UpdateStatusRows(
            check: ({client, required currentVersion, format}) async => null,
            shouldRun: () => true,
          ),
          [_appInfo()],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();

      expect(find.text('You are on the latest version.'), findsOneWidget);
    });

    testWidgets('the manual check ignores a dismissal', (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        _hosting(
          Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return UpdateStatusRows(
                check: ({client, required currentVersion, format}) async =>
                    _update,
                shouldRun: () => true,
              );
            },
          ),
          [
            dismissedBannerVersionProvider.overrideWith((ref) => '0.79.0'),
            _appInfo(),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();

      expect(
        container.read(inSessionUpdateProvider)?.version,
        '0.79.0',
        reason:
            'someone who presses Check is asking; answering "up to date" '
            'because they dismissed the banner earlier would be a lie',
      );
      expect(find.text('Version 0.79.0 is available.'), findsOneWidget);
    });

    testWidgets('is absent where the check never runs', (tester) async {
      await tester.pumpWidget(
        _hosting(
          UpdateStatusRows(
            check: ({client, required currentVersion, format}) async => _update,
            shouldRun: () => false,
          ),
          const [],
        ),
      );

      expect(
        find.text('Check for updates'),
        findsNothing,
        reason: 'a control that can never find anything is worse than none',
      );
    });
  });
}
