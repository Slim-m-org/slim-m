// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Only an error that means placing would fail again (a refusal, a canvas
/// that did not load) disarms pen, note, shape and paste; a failed reorder or
/// delete is just a banner.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_engine.dart';
import 'package:slimm_app/src/screens/canvas/canvas_forbidden_message.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_pane_harness.dart';

bool _penEnabled(WidgetTester tester) =>
    tester
        .widget<AppIconButton>(
          find
              .ancestor(
                of: find.bySemanticsLabel(
                  RegExp(r"^(Pen|Can't draw right now)$"),
                ),
                matching: find.byType(AppIconButton),
              )
              .first,
        )
        .onPressed !=
    null;

const _refused = "You don't have permission to draw here right now.";

Future<ProviderContainer> _pump(WidgetTester tester) async {
  final fixture = CanvasPaneFixture();
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pumpAndSettle();
  return container;
}

void _report(ProviderContainer container, String message) =>
    container.read(canvasEngineProvider('c1').notifier).reportError(message);

Future<({AppMenuItem paste, AppMenuItem note})> _emptySpaceMenu(
  WidgetTester tester,
) async {
  await tester.tapAt(
    screenFor(tester, const Offset(300, 200)),
    buttons: kSecondaryButton,
  );
  await tester.pumpAndSettle();
  return (
    paste: tester.widget<AppMenuItem>(
      find.widgetWithText(AppMenuItem, 'Paste image'),
    ),
    note: tester.widget<AppMenuItem>(
      find.widgetWithText(AppMenuItem, 'Add note'),
    ),
  );
}

void main() {
  testWidgets('a failed reorder does not disable the Pen button', (
    tester,
  ) async {
    final container = await _pump(tester);
    expect(_penEnabled(tester), isTrue, reason: 'baseline');

    _report(container, 'That could not be reordered.');
    await tester.pumpAndSettle();

    expect(find.text('That could not be reordered.'), findsOneWidget);
    expect(_penEnabled(tester), isTrue);
  });

  testWidgets('a draw refusal disables the Pen button', (tester) async {
    final container = await _pump(tester);

    _report(container, _refused);
    await tester.pumpAndSettle();

    expect(_penEnabled(tester), isFalse);
  });

  testWidgets('a timeout freeze disables the Pen button', (tester) async {
    final container = await _pump(tester);

    _report(
      container,
      canvasDrawForbiddenMessage(
        DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      ),
    );
    await tester.pumpAndSettle();

    expect(_penEnabled(tester), isFalse);
  });

  testWidgets('a canvas that failed to load disables the Pen button', (
    tester,
  ) async {
    final container = await _pump(tester);

    _report(container, CanvasEngine.genericLoadError);
    await tester.pumpAndSettle();

    expect(_penEnabled(tester), isFalse);
  });

  testWidgets(
    'the right-click menu agrees with the overflow menu on a refusal',
    (tester) async {
      final container = await _pump(tester);
      _report(container, _refused);
      await tester.pumpAndSettle();

      final menu = await _emptySpaceMenu(tester);

      expect(menu.paste.onTap, isNull);
      expect(menu.note.onTap, isNull);
    },
  );

  testWidgets('the right-click menu stays live after a failed reorder', (
    tester,
  ) async {
    final container = await _pump(tester);
    _report(container, 'That could not be reordered.');
    await tester.pumpAndSettle();

    final menu = await _emptySpaceMenu(tester);

    expect(menu.paste.onTap, isNotNull);
    expect(menu.note.onTap, isNotNull);
  });
}
