// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// System Back on the phone channel list must reach the popup on top.
///
/// go_router's `popRoute` dereferences every shell route's navigator, and
/// the phone list drops the shell's routed child, so nothing mounted that
/// navigator: the lookup threw, `didPopRoute` answered false, and Android
/// sent the task home with the popup still open.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/home_shell.dart';

import '../settings/home_shell_harness.dart';

void main() {
  testWidgets('system back closes a dialog over the phone channel list', (
    tester,
  ) async {
    final s = setup();
    await pumpAtWidth(tester, s.container, 400);
    final context = tester.element(
      find.byWidgetPredicate((w) => w is HomeShell),
    );
    unawaited(
      showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (_) => const AlertDialog(title: Text('popup')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('popup'), findsOneWidget);

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(handled, isTrue);
    expect(find.text('popup'), findsNothing);
    await teardown(tester, s.container, s.db);
  });

  testWidgets('system back with nothing open is left to the platform', (
    tester,
  ) async {
    final s = setup();
    await pumpAtWidth(tester, s.container, 400);

    expect(await tester.binding.handlePopRoute(), isFalse);
    await teardown(tester, s.container, s.db);
  });
}
