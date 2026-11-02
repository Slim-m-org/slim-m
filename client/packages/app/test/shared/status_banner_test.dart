// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [StatusBanner]: every severity but error clears itself, error waits to be dismissed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/status_banner.dart';
import 'package:slimm_design_system/design_system.dart';

final _close = find.byIcon(AppIcons.dismiss);

Future<void> _pump(
  WidgetTester tester,
  BannerSeverity severity, {
  VoidCallback? onDismiss,
  bool sticky = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Column(
        children: [
          StatusBanner(
            key: const ValueKey('banner'),
            message: 'Heads up',
            severity: severity,
            onDismiss: onDismiss,
            sticky: sticky,
          ),
          const Text('below'),
        ],
      ),
    ),
  ),
);

void main() {
  test('only error has no timer, and warning outlasts info', () {
    expect(BannerSeverity.error.autoDismiss, isNull);
    expect(
      BannerSeverity.warning.autoDismiss! > BannerSeverity.info.autoDismiss!,
      isTrue,
    );
  });

  for (final severity in [
    BannerSeverity.info,
    BannerSeverity.success,
    BannerSeverity.warning,
  ]) {
    testWidgets('$severity clears itself and reports it', (tester) async {
      var dismissed = 0;
      await _pump(tester, severity, onDismiss: () => dismissed++);
      expect(find.text('Heads up'), findsOneWidget);

      await tester.pump(severity.autoDismiss! - const Duration(seconds: 1));
      expect(find.text('Heads up'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Heads up'), findsNothing);
      expect(dismissed, 1);
    });
  }

  testWidgets('an error stays, and has no close button without a handler', (
    tester,
  ) async {
    await _pump(tester, BannerSeverity.error);
    await tester.pump(const Duration(minutes: 5));
    expect(find.text('Heads up'), findsOneWidget);
    expect(_close, findsNothing);
  });

  testWidgets('an error with a handler closes only by the button', (
    tester,
  ) async {
    var dismissed = 0;
    await _pump(tester, BannerSeverity.error, onDismiss: () => dismissed++);
    await tester.pump(const Duration(minutes: 5));
    expect(find.text('Heads up'), findsOneWidget);

    await tester.tap(_close);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Heads up'), findsNothing);
    expect(dismissed, 1);
  });

  testWidgets('a sticky banner ignores its severity timer', (tester) async {
    await _pump(tester, BannerSeverity.info, sticky: true);
    await tester.pump(const Duration(minutes: 5));
    expect(find.text('Heads up'), findsOneWidget);
  });

  testWidgets('a sticky banner has no close button', (tester) async {
    await _pump(tester, BannerSeverity.warning, sticky: true, onDismiss: () {});
    expect(_close, findsNothing);
  });

  testWidgets('it is a compact pill, not the full width of its parent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(tester, BannerSeverity.info);
    final span =
        tester.getRect(_close).right -
        tester.getRect(find.text('Heads up')).left;
    expect(span, lessThan(kStatusBannerMaxWidth));
  });
}
