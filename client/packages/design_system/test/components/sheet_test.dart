// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A modal is whatever the window can carry.
///
/// Every modal in the app was a bottom sheet, which is a phone affordance: it
/// sits against the edge a thumb reaches and its drag handle means something
/// to a thumb. On a desktop window one reads as a phone screen pasted along
/// the bottom of a monitor, offers a handle a mouse cannot usefully drag, and
/// gets cut off by an edge it cannot see. The avatar crop sheet was cut off
/// exactly that way and could not be completed at all.
///
/// The `reduce motion` group below covers a gap of its own: `showDialog` and
/// `showModalBottomSheet` each drive their own entrance with a plain
/// `AnimationController` Flutter owns, keyed to the platform's own
/// reduce-motion feature rather than this app's `MediaQuery` override - the
/// one `MotionOverride` cannot reach unless `showAppSheet` hands Flutter an
/// `AnimationStyle` itself. Asserted from both sides, the same shape
/// `reduce_motion_test.dart` already uses: a reduce-motion branch that is
/// always taken would pass a one-sided test while quietly losing the sheet's
/// own entrance for everybody.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const Size _phone = Size(390, 844);
const Size _desktop = Size(1280, 900);

/// The panel itself, not [Dialog], whose own box is the whole padded screen
/// and so is centred and full-width no matter what the panel does.
Finder get _panel => find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

/// Pumps a screen with one button that opens [showAppSheet], and taps it.
///
/// [reduceMotion] is applied with `copyWith` on the ambient `MediaQuery`
/// `WidgetsApp` already resolved from `window`, not a bare replacement: a
/// bare [MediaQueryData] defaults its own `size` to [Size.zero], which would
/// send every case here down the compact branch regardless of `window`. The
/// second [Builder] is what makes that override reach `showAppSheet` at
/// all - the outer one's own `context` sits above it, not below.
Future<void> _pumpOpener(
  WidgetTester tester,
  Size window, {
  double maxWidth = kSheetMaxWidth,
  bool bare = false,
  bool reduceMotion = false,
  Widget body = const Text('sheet body'),
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                // A plain tap target, not TextButton: its own ink-splash animation is a second one the assertions below would trip over.
                child: GestureDetector(
                  onTap: () => showAppSheet<void>(
                    context,
                    maxWidth: maxWidth,
                    bare: bare,
                    builder: (_) => body,
                  ),
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

/// [_pumpOpener] plus settling all the way, for every test that only cares
/// about the sheet's final, resting shape.
Future<void> _open(
  WidgetTester tester,
  Size window, {
  double maxWidth = kSheetMaxWidth,
  bool bare = false,
}) async {
  await _pumpOpener(
    tester,
    window,
    maxWidth: maxWidth,
    bare: bare,
    // Greedy on purpose: content that asks for more width than the cap is
    // the only thing that proves the cap binds.
    body: const SizedBox(
      width: 2000,
      height: 120,
      child: Center(child: Text('sheet body')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a phone gets a bottom sheet', (tester) async {
    await _open(tester, _phone);

    expect(find.text('sheet body'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets(
    'a bottom sheet keeps its content clear of a home indicator, even when '
    'the sheet itself never asked to',
    (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showAppSheet<void>(
                    context,
                    // A caller that never wraps its own content in SafeArea, the common shape.
                    builder: (_) => const Text('sheet body'),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(SafeArea), findsOneWidget);
      final safeArea = tester.widget<SafeArea>(find.byType(SafeArea));
      expect(safeArea.bottom, isTrue);
      expect(safeArea.top, isFalse);
    },
  );

  testWidgets('a desktop window gets a dialog', (tester) async {
    await _open(tester, _desktop);

    expect(find.text('sheet body'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('the dialog does not grow with the monitor', (tester) async {
    await _open(tester, _desktop);

    final box = tester.getRect(_panel);
    expect(box.width, lessThanOrEqualTo(kSheetMaxWidth));
    expect(box.width, lessThan(_desktop.width / 2));
  });

  testWidgets('the dialog is centred, not stuck to an edge', (tester) async {
    await _open(tester, _desktop);

    final box = tester.getRect(_panel);
    expect(box.center.dx, closeTo(_desktop.width / 2, 1));
    expect(box.center.dy, closeTo(_desktop.height / 2, 1));
    // The failure that started this: content past the bottom of the window.
    expect(box.bottom, lessThanOrEqualTo(_desktop.height));
  });

  testWidgets('content that draws its own surface is not double-framed', (
    tester,
  ) async {
    await _open(tester, _desktop, bare: true);

    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.backgroundColor, Colors.transparent);
    expect(dialog.shape, isNull);
  });

  group('reduce motion', () {
    // See this file's own library doc for why this group exists at all.
    testWidgets('the bottom sheet opens with no running animation', (
      tester,
    ) async {
      await _pumpOpener(tester, _phone, reduceMotion: true);
      await tester.pump();

      expect(find.text('sheet body'), findsOneWidget);
      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason: 'nothing may keep ticking once the viewer has asked it not to',
      );
    });

    testWidgets('the bottom sheet enters over the modal duration token', (
      tester,
    ) async {
      await _pumpOpener(tester, _phone);
      await tester.pump();
      await tester.pump(AppMotion.slow - const Duration(milliseconds: 10));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('the bottom sheet still animates by default', (tester) async {
      await _pumpOpener(tester, _phone);
      await tester.pump();

      expect(
        tester.hasRunningAnimations,
        isTrue,
        reason: "a viewer who asked for nothing keeps the sheet's own stock "
            "entrance rather than this app's override collapsing it",
      );
      await tester.pumpAndSettle();
    });

    testWidgets('the dialog opens with no running animation', (tester) async {
      await _pumpOpener(tester, _desktop, reduceMotion: true);
      await tester.pump();

      expect(find.text('sheet body'), findsOneWidget);
      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason: 'nothing may keep ticking once the viewer has asked it not to',
      );
    });

    testWidgets('the dialog still animates by default', (tester) async {
      await _pumpOpener(tester, _desktop);
      await tester.pump();

      expect(
        tester.hasRunningAnimations,
        isTrue,
        reason: "a viewer who asked for nothing keeps the dialog's own stock "
            "entrance rather than this app's override collapsing it",
      );
      await tester.pumpAndSettle();
    });
  });
}
