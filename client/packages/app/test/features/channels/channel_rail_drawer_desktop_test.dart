// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The edge-swipe drawer at compact width, but with the theme's platform
/// forced to a desktop family (as a real desktop build always reports via
/// `defaultTargetPlatform`), rather than the `TargetPlatform.android` the
/// test harness otherwise defaults to. Flutter's own `Drawer` disables its
/// edge-swipe gesture whenever `Theme.of(context).platform` is a desktop
/// family, with no regard for the window's actual width - so
/// `channel_rail_drawer_test.dart`'s identical drag never caught this: it
/// runs under the harness default, which reads as mobile. This file is what
/// a desktop window narrowed below `kCompactWidth` actually gets.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_chrome.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../desktop/support/desktop_shell_fixture.dart';
import '../../ui_snapshot_support.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _pumpAtWidth(
  WidgetTester tester,
  double width,
  TargetPlatform platform, {
  String location = '/channels/c-general',
  DesktopWindowShell? shell,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(
    extraOverrides: [
      if (shell != null) desktopWindowShellProvider.overrideWithValue(shell),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => DesktopChrome(child: child!),
        theme: buildTheme(
          Brightness.dark,
          AppTokens.dark,
        ).copyWith(platform: platform),
        routerConfig: fixtureRouter(location),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

/// A drag starting inside the edge strip, well past the open threshold,
/// settled once the drawer finishes animating.
Future<void> _dragFromLeftEdge(WidgetTester tester) async {
  await tester.dragFrom(const Offset(5, 300), const Offset(300, 0));
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      'an edge drag reveals the rail at compact width on a desktop host '
      '($platform)',
      (tester) async {
        final fixture = await _pumpAtWidth(tester, 500, platform);
        expect(find.byType(ChannelRail), findsNothing);

        await _dragFromLeftEdge(tester);

        expect(
          find.byType(ChannelRail),
          findsOneWidget,
          reason:
              'a narrow desktop window is the same situation as a phone at '
              'the same width, per desktop-vs-mobile.md',
        );
        expect(
          find.byType(CompactChannelAppBar),
          findsOneWidget,
          reason:
              'the rail must show as a drawer over the open conversation, '
              'not because the drag instead popped the route back to the '
              'bare channel list',
        );

        await teardownFixture(tester, fixture.container, fixture.db);
      },
    );
  }

  testWidgets(
    'the edge strip starts past the resize handle on a frameless window',
    (tester) async {
      final fixture = await _pumpAtWidth(
        tester,
        500,
        TargetPlatform.linux,
        shell: shellFor(null, active: true, frameless: true),
      );
      expect(find.byType(ChannelRail), findsNothing);

      // Inside the real resize handle's band: a resize grab, not a drawer open.
      await tester.dragFrom(const Offset(2, 300), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.byType(ChannelRail), findsNothing);

      // Just past the resize handle: the drawer's own territory.
      await tester.dragFrom(const Offset(10, 300), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.byType(ChannelRail), findsOneWidget);

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );
}
