// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The 599/600 chrome swap is bridged with a short fade rather than a
/// one-frame interface replacement, and reduce motion keeps the instant
/// swap.
///
/// The bridge is deliberately a keyed one-shot fade, never an
/// AnimatedSwitcher: a switcher keeps the outgoing scaffold mounted, and
/// both copies would then hold the shell's one routed child - a Navigator
/// whose GlobalKeys cannot exist twice. This suite pins the fade actually
/// replaying on a resize across the breakpoint, which is what a switcher
/// mutation or a dropped key would silently lose.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/home_shell.dart';

import 'features/settings/home_shell_harness.dart';

double _shellOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byType(HomeShell),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  testWidgets('crossing the breakpoint fades the new chrome in', (
    tester,
  ) async {
    final fixture = setup();
    await pumpAtWidth(tester, fixture.container, 599);
    expect(_shellOpacity(tester), 1);

    tester.view.physicalSize = const Size(700, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final bridging = _shellOpacity(tester);
    expect(bridging, greaterThan(0));
    expect(bridging, lessThan(1));

    await tester.pumpAndSettle();
    expect(_shellOpacity(tester), 1);
    await teardown(tester, fixture.container, fixture.db);
  });

  testWidgets('a resize on the same side of the breakpoint never re-fades', (
    tester,
  ) async {
    final fixture = setup();
    await pumpAtWidth(tester, fixture.container, 700);

    tester.view.physicalSize = const Size(900, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(_shellOpacity(tester), 1);

    await tester.pumpAndSettle();
    await teardown(tester, fixture.container, fixture.db);
  });

  testWidgets('reduce motion keeps the instant swap', (tester) async {
    final fixture = setup();
    await pumpAtWidth(tester, fixture.container, 599, reduceMotion: true);

    tester.view.physicalSize = const Size(700, 900);
    await tester.pump();
    expect(_shellOpacity(tester), 1);

    await tester.pumpAndSettle();
    await teardown(tester, fixture.container, fixture.db);
  });
}
