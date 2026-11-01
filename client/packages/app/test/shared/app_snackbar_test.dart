// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `showAppSnackbar` is this app's one choke point for a `SnackBar`, closing
/// the gap `reduce_motion_gate_test.dart`'s own library doc names as left
/// undone: `ScaffoldMessengerState.showSnackBar` drives its own entrance and
/// exit with a plain `AnimationController` the messenger creates once,
/// keyed to nothing this app controls unless `snackBarAnimationStyle` is
/// handed in explicitly - the same escape hatch `sheet_test.dart`'s own
/// "reduce motion" group already proved for `showDialog` and
/// `showModalBottomSheet` inside `showAppSheet`.
///
/// `tester.hasRunningAnimations` is the same behavioural assertion that
/// file uses, deliberately not a textual check for the keyword: a call that
/// carries `snackBarAnimationStyle:` in its source but passes the wrong
/// value, or passes it conditioned on the wrong flag, would still read as
/// "present" to a textual gate while a viewer who asked for less motion
/// keeps watching a snack bar slide in.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/app_snackbar.dart';

/// Pumps a screen with one button that calls [showAppSnackbar], and taps it.
///
/// [reduceMotion] is applied with `copyWith` on the ambient `MediaQuery`
/// `WidgetsApp` already resolved from `window`, the same technique
/// `sheet_test.dart`'s own `_pumpOpener` uses and for the same reason: a
/// bare `MediaQueryData` would default other fields in ways nothing here
/// means to test.
Future<void> _pumpOpener(
  WidgetTester tester, {
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: GestureDetector(
                  onTap: () => showAppSnackbar(context, 'a message'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
}

void main() {
  group('reduce motion', () {
    testWidgets('the snack bar opens with no running animation', (
      tester,
    ) async {
      await _pumpOpener(tester, reduceMotion: true);
      await tester.pump();

      expect(find.text('a message'), findsOneWidget);
      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason: 'nothing may keep ticking once the viewer has asked it not to',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('the snack bar still animates by default', (tester) async {
      await _pumpOpener(tester);
      await tester.pump();

      expect(
        tester.hasRunningAnimations,
        isTrue,
        reason:
            "a viewer who asked for nothing keeps the snack bar's own "
            "stock entrance rather than this app's override collapsing it",
      );
      await tester.pumpAndSettle();
    });
  });

  testWidgets('does nothing when there is no ScaffoldMessenger above the '
      'context, rather than throwing', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) => GestureDetector(
              onTap: () => showAppSnackbar(context, 'a message'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('a message'), findsNothing);
  });
}
