// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web update notice sits in the banner column above the content, so it
/// never overlaps the offline banner or the first message line, and the
/// floating pill stands down while it is docked.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/web_update/web_update_banner_host.dart';
import 'package:slimm_app/src/web_update/web_update_pill.dart';
import 'package:slimm_app/src/web_update/web_update_watch.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  for (final width in const [390.0, 1280.0]) {
    testWidgets('the docked notice clears the content at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          runningWebBuildProvider.overrideWithValue('aaa'),
          webUpdateSupportedProvider.overrideWithValue(true),
          webBuildFetcherProvider.overrideWithValue(() async => 'bbb'),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: Stack(
                children: [
                  const WebUpdateBannerHost(
                    child: Column(
                      children: [
                        Text('Offline, retrying'),
                        Text('first message line'),
                      ],
                    ),
                  ),
                  const Positioned.fill(child: WebUpdatePill()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(webUpdateWatchInterval);
      await tester.pump();

      expect(find.text('Reload'), findsOneWidget);
      final banner = tester.getRect(find.text('New version available'));
      for (final line in ['Offline, retrying', 'first message line']) {
        expect(
          banner.bottom,
          lessThanOrEqualTo(tester.getTopLeft(find.text(line)).dy),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
  }
}
