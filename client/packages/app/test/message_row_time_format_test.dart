// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The grouped continuation gutter's timestamp follows the 12/24-hour
/// preference (#38), not a hardcoded format. Split out of
/// `message_row_test.dart`, which is already at its line budget and whose
/// own scope is grouping, not the exact text a timestamp renders.
///
/// The gutter timestamp is also hover-gated (backlog #119): a grouped row's
/// sent time no longer sits in the left gutter at rest, only while a mouse
/// hovers the row, so every case here hovers first.
///
/// PR #1289 held a `FittedBox` version of the gutter mark that rendered as
/// small as 6px, half the type scale's floor, and defeated the reader's
/// text-scale setting: `FittedBox` does not change the size a `RenderBox`
/// reports for itself, only a paint-time transform, so `tester.getSize` on
/// the `RichText` alone cannot see a squeeze - it reads the same either way.
/// [_onScreenSize] instead reads the transform to the root, which is what
/// actually changes, and the geometry tests below compare that against an
/// unconstrained reference render of the same string.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/display_preferences.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/message_row_identity.dart';

import 'message_row_harness.dart';

Future<void> _pumpRow(
  WidgetTester tester,
  TimeFormatPreference preference, {
  required bool grouped,
  TextScaler? textScaler,
}) {
  final row = harness(
    MessageRow(
      message: message(),
      grouped: grouped,
      showNewDivider: false,
      knownUsernames: const {},
      actions: noActions,
      editing: false,
      callbacks: MessageRowCallbacks(
        onRetry: () {},
        onDiscard: () {},
        onPickReaction: (_) {},
        onReactionTap: (_) {},
        onVote: (_) {},
        onSubmitEdit: (_) {},
        onCancelEdit: () {},
      ),
    ),
    overrides: [
      timeFormatControllerProvider.overrideWith(
        (ref) => TimeFormatController(ref)..state = preference,
      ),
    ],
  );
  return tester.pumpWidget(
    textScaler == null
        ? row
        : Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: row,
            ),
          ),
  );
}

Future<void> _pumpGrouped(
  WidgetTester tester,
  TimeFormatPreference preference, {
  TextScaler? textScaler,
}) => _pumpRow(tester, preference, grouped: true, textScaler: textScaler);

Future<void> _hover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
  await tester.pumpAndSettle();
}

/// For a test that re-pumps a second tree and needs to hover it too: a
/// second [_hover] call would add a second mouse pointer without removing
/// the first, which the framework's own mouse tracker rejects. Re-moving
/// the one pointer this returns re-hovers whatever tree is live at the
/// time.
Future<TestGesture> _hoverable(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  return mouse;
}

Future<void> _moveOnto(WidgetTester tester, TestGesture mouse) async {
  await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
  await tester.pumpAndSettle();
}

/// The gutter's own [RichText], found the same way in every geometry case
/// below.
Finder _gutterRichText() => find.descendant(
  of: find.byType(MessageTimeMark),
  matching: find.byType(RichText),
);

/// The size a [RenderBox] actually occupies once every ancestor transform -
/// a `FittedBox`'s scale included - is applied, rather than the size it
/// reports for its own layout (see this file's own doc comment).
Size _onScreenSize(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  final transform = box.getTransformTo(null);
  final topLeft = MatrixUtils.transformPoint(transform, Offset.zero);
  final bottomRight = MatrixUtils.transformPoint(
    transform,
    Offset(box.size.width, box.size.height),
  );
  return Size(bottomRight.dx - topLeft.dx, bottomRight.dy - topLeft.dy);
}

void main() {
  testWidgets('h24 shows the zero-padded 24-hour form on hover', (
    tester,
  ) async {
    await _pumpGrouped(tester, TimeFormatPreference.h24);
    await _hover(tester);

    expect(
      find.text(formatMessageTime(1700000000000, use24Hour: true)),
      findsOneWidget,
    );
  });

  testWidgets('h12 shows the compact 12-hour form instead, on hover', (
    tester,
  ) async {
    await _pumpGrouped(tester, TimeFormatPreference.h12);
    await _hover(tester);

    expect(
      find.text(formatMessageTime(1700000000000, use24Hour: false)),
      findsOneWidget,
    );
    expect(
      find.text(formatMessageTime(1700000000000, use24Hour: true)),
      findsNothing,
    );
  });

  testWidgets(
    'h12 renders the gutter timestamp at the same on-screen size as the '
    'unconstrained header, never scaled down to fit',
    (tester) async {
      // The header's copy has room to spare, so its size is the true, unscaled one.
      await _pumpRow(tester, TimeFormatPreference.h12, grouped: false);
      await tester.pumpAndSettle();
      final headerSize = _onScreenSize(tester, _gutterRichText());

      await _pumpGrouped(tester, TimeFormatPreference.h12);
      await _hover(tester);
      final gutterSize = _onScreenSize(tester, _gutterRichText());

      expect(gutterSize.width, closeTo(headerSize.width, 0.5));
      expect(gutterSize.height, closeTo(headerSize.height, 0.5));
      // Single line: a wrapped render would be roughly double this height.
      expect(gutterSize.height, lessThan(20));
      // Never below the type scale's floor (AppText.micro, 11px).
      expect(gutterSize.height, greaterThanOrEqualTo(13));
    },
  );

  testWidgets('h12 grows the gutter timestamp at 200% text scale rather than '
      'squeezing it back down', (tester) async {
    final mouse = await _hoverable(tester);

    await _pumpGrouped(tester, TimeFormatPreference.h12);
    await _moveOnto(tester, mouse);
    final baseline = _onScreenSize(tester, _gutterRichText());

    await _pumpGrouped(
      tester,
      TimeFormatPreference.h12,
      textScaler: const TextScaler.linear(2),
    );
    await _moveOnto(tester, mouse);
    final scaled = _onScreenSize(tester, _gutterRichText());

    // A squeeze-to-fit stays pinned to the gutter's own width; this should grow.
    expect(scaled.height, greaterThan(baseline.height * 1.5));
    expect(scaled.width, greaterThan(baseline.width * 1.5));
  });

  testWidgets(
    'the message column does not move when the gutter timestamp appears '
    'on hover',
    (tester) async {
      await _pumpGrouped(tester, TimeFormatPreference.h12);
      final restPosition = tester.getTopLeft(find.text('hello there'));

      await _hover(tester);
      final hoveredPosition = tester.getTopLeft(find.text('hello there'));

      expect(hoveredPosition, restPosition);
    },
  );
}
