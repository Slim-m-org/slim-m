// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The toast layer renders what the queue holds, positions itself by width
/// (bottom-right wide, top on a phone), dismisses on tap, and clears a toast
/// once its timer elapses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/widgets/toast_overlay.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host() => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: const Scaffold(
    body: Stack(children: [Positioned.fill(child: ToastOverlay())]),
  ),
);

void main() {
  testWidgets('a fired toast renders its message, and a tap dismisses it', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _host()),
    );
    expect(find.byType(AppToast), findsNothing);

    container
        .read(toastsProvider.notifier)
        .show('Invite link copied', severity: AppToastSeverity.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Invite link copied'), findsOneWidget);
    expect(find.byType(AppToast), findsOneWidget);

    await tester.tap(find.byType(AppToast));
    await tester.pumpAndSettle();
    expect(find.byType(AppToast), findsNothing);
  });

  testWidgets('a toast clears itself once its duration elapses', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _host()),
    );

    container
        .read(toastsProvider.notifier)
        .show('Saved', duration: const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Saved'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('the toast sits low on a wide window and high on a phone', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;

    Future<Offset> centerAt(double width) async {
      tester.view.physicalSize = Size(width, 800);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: _host()),
      );
      container
          .read(toastsProvider.notifier)
          .show('Here', duration: Duration.zero);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return tester.getCenter(find.byType(AppToast));
    }

    final wide = await centerAt(1200);
    expect(wide.dy, greaterThan(400), reason: 'bottom half on a wide window');

    final phone = await centerAt(400);
    expect(phone.dy, lessThan(400), reason: 'top on a phone');
  });
}
