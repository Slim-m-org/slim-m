// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `RailHeader` renders on every platform, the desktop title bar included
/// (0012's 2026-09-25 addendum): the title bar is the window's own title, the
/// rail header is the Space, so the header must not vanish under the title bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart'
    show RailHeader;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../desktop/support/desktop_shell_fixture.dart';
import '../../ui_snapshot_support.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _pumpAtExpandedWidth(
  WidgetTester tester, {
  DesktopWindowShell? shell,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
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
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  testWidgets('the rail header shows at expanded width with no title bar', (
    tester,
  ) async {
    final fixture = await _pumpAtExpandedWidth(tester);

    expect(find.byType(RailHeader), findsOneWidget);

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets(
    'the rail header still shows while the desktop title bar is mounted: '
    'the title bar is the window title, the rail header is the Space',
    (tester) async {
      final fixture = await _pumpAtExpandedWidth(
        tester,
        shell: shellFor(null, active: true, frameless: true),
      );

      expect(find.byType(RailHeader), findsOneWidget);

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );
}
