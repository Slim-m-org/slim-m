// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An edited row says so: the whole row takes the raised fill, the header
/// carries an EDITING tag, and the key hints are keycaps (`AppKbd`, the
/// component the empty pane uses) instead of a code-style sentence.
///
/// Geometry, not presence: a tag that exists but sits on the wrong line, or
/// keycaps that spill out of the field, would pass a find and fail the design.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_edit_field.dart';
import 'package:slimm_app/src/widgets/message_hover_toolbar.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

Widget _row({
  bool editing = true,
  bool grouped = false,
  ValueChanged<String>? onSubmit,
  double width = 600,
}) => harness(
  Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: width,
      child: MessageRow(
        message: message(content: 'yes, it was the seq ordering'),
        grouped: grouped,
        showNewDivider: false,
        knownUsernames: const {},
        actions: noActions,
        editing: editing,
        callbacks: MessageRowCallbacks(
          onRetry: noop,
          onDiscard: noop,
          onPickReaction: (_) {},
          onReactionTap: (_) {},
          onVote: (_) {},
          onSubmitEdit: onSubmit ?? (_) {},
          onCancelEdit: noop,
        ),
      ),
    ),
  ),
  platform: TargetPlatform.linux,
);

Finder get _tag => find.widgetWithText(AppBadge, 'EDITING');

Color? _fill(WidgetTester tester) {
  final decoration = tester
      .widget<AnimatedContainer>(find.byKey(MessageRow.hoverFillKey))
      .decoration;
  return (decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets('the whole row takes the raised fill while editing', (
    tester,
  ) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();
    final tokens = Theme.of(
      tester.element(find.byType(MessageRow)),
    ).extension<AppTokens>()!;
    expect(_fill(tester), tokens.surfaceRaised);
    final fill = tester.getRect(find.byKey(MessageRow.hoverFillKey));
    expect(fill, tester.getRect(find.byType(MessageContextMenuRegion)));

    await tester.pumpWidget(_row(editing: false));
    await tester.pumpAndSettle();
    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('the field has air between its edge and the fill edge', (
    tester,
  ) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    final fill = tester.getRect(find.byKey(MessageRow.hoverFillKey));
    final field = tester.getRect(find.byType(MessageEditField));
    expect(fill.bottom - field.bottom, greaterThanOrEqualTo(AppSpacing.s8));
  });

  testWidgets('the header line carries an EDITING tag beside the time', (
    tester,
  ) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    final tag = tester.getRect(_tag);
    final name = tester.getRect(find.text('Priya'));
    final field = tester.getRect(find.byType(MessageEditField));
    expect(tag.center.dy, closeTo(name.center.dy, 4));
    expect(tag.left, greaterThan(name.right));
    expect(tag.bottom, lessThanOrEqualTo(field.top));
  });

  testWidgets('a grouped row has no header, so the tag sits above the field', (
    tester,
  ) async {
    await tester.pumpWidget(_row(grouped: true));
    await tester.pumpAndSettle();

    final tag = tester.getRect(_tag);
    final field = tester.getRect(find.byType(MessageEditField));
    expect(tag.bottom, lessThanOrEqualTo(field.top));
    expect(tag.left, closeTo(field.left, 1));
  });

  testWidgets('no tag on a row that is not being edited', (tester) async {
    await tester.pumpWidget(_row(editing: false));
    expect(_tag, findsNothing);
  });

  testWidgets('the hints are keycaps inside the field, below the text', (
    tester,
  ) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    expect(find.textContaining('escape to cancel'), findsNothing);
    final labels = tester
        .widgetList<AppKbd>(find.byType(AppKbd))
        .map((k) => k.label)
        .toList();
    expect(labels, ['Esc', 'Enter', 'Shift', 'Enter']);

    final field = tester.getRect(find.byType(MessageEditField));
    final input = tester.getRect(find.byType(TextField));
    for (final cap in find.byType(AppKbd).evaluate()) {
      final r = tester.getRect(find.byWidget(cap.widget));
      expect(r.top, greaterThanOrEqualTo(input.bottom));
      expect(
        field.contains(r.topLeft) && field.contains(r.bottomRight),
        isTrue,
      );
    }
    expect(find.text('newline'), findsOneWidget);
    expect(find.text('cancel'), findsOneWidget);
    expect(find.text('save'), findsOneWidget);
  });

  testWidgets('the keycaps stay inside the field in a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_row(width: 320));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final field = tester.getRect(find.byType(MessageEditField));
    for (final cap in find.byType(AppKbd).evaluate()) {
      final r = tester.getRect(find.byWidget(cap.widget));
      expect(r.right, lessThanOrEqualTo(field.right));
    }
    final save = tester.getRect(find.text('Save'));
    expect(save.right, lessThanOrEqualTo(field.right));
  });

  testWidgets('a soft keyboard shows no keycaps', (tester) async {
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: true,
          callbacks: MessageRowCallbacks(
            onRetry: noop,
            onDiscard: noop,
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (_) {},
            onSubmitEdit: (_) {},
            onCancelEdit: noop,
          ),
        ),
        platform: TargetPlatform.android,
      ),
    );
    expect(find.byType(AppKbd), findsNothing);
    expect(_tag, findsOneWidget);
  });

  testWidgets('Shift+Enter is a newline and Enter saves, as the keycaps say', (
    tester,
  ) async {
    final submitted = <String>[];
    await tester.pumpWidget(_row(onSubmit: submitted.add));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'one');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(submitted, isEmpty, reason: 'Shift+Enter must not save');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submitted, hasLength(1));
  });

  testWidgets('the hover toolbar does not sit over the field while editing', (
    tester,
  ) async {
    await tester.pumpWidget(_row());
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(-50, -50));
    await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
    await tester.pumpAndSettle();

    expect(find.byKey(MessageHoverToolbar.plateKey), findsNothing);
  });
}
