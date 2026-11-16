// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one sheet a name is typed in: when Save is offered, what a save does,
/// and a refusal that stays on the sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/name_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/async_wait.dart';

class _Sheet {
  final saved = <String>[];
  Object? failWith;
  bool? result;
}

Future<_Sheet> _open(
  WidgetTester tester, {
  String initial = 'Lobby',
  bool requireChange = true,
  String? Function(String)? problem,
  String? blocked,
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sheet = _Sheet();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => AppButton(
              label: 'Open',
              onPressed: () async {
                sheet.result = await showNameSheet(
                  context,
                  title: 'Rename $initial',
                  fieldLabel: 'Name',
                  maxChars: 8,
                  whatFailed: 'rename it',
                  initial: initial,
                  requireChange: requireChange,
                  problem: problem,
                  blocked: blocked,
                  onSave: (ref, name) async {
                    if (sheet.failWith case final error?) throw error;
                    sheet.saved.add(name);
                  },
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await pumpFrames(tester, frames: 20);
  return sheet;
}

Finder get _field => find.byWidgetPredicate((w) => w is EditableText);
Finder get _save => find.widgetWithText(AppButton, 'Save name');

void main() {
  testWidgets('Save waits for a changed, non-empty name that fits', (
    tester,
  ) async {
    final sheet = await _open(tester);
    await tester.tap(_save);
    await pumpFrames(tester);
    expect(sheet.saved, isEmpty, reason: 'unchanged');

    await tester.enterText(_field, '   ');
    await tester.pump();
    await tester.tap(_save);
    await pumpFrames(tester);
    expect(sheet.saved, isEmpty, reason: 'empty');

    await tester.enterText(_field, 'Far too long');
    await tester.pump();
    await tester.tap(_save);
    await pumpFrames(tester);
    expect(sheet.saved, isEmpty, reason: 'over the limit');
  });

  testWidgets('a save sends the trimmed name once and closes', (tester) async {
    final sheet = await _open(tester);
    await tester.enterText(_field, '  Den ');
    await tester.pump();
    await tester.tap(_save);
    await pumpFrames(tester, frames: 20);

    expect(sheet.saved, ['Den']);
    expect(sheet.result, isTrue);
    expect(find.text('Rename Lobby'), findsNothing);
  });

  testWidgets('a refusal stays on the sheet as an inline error', (
    tester,
  ) async {
    final sheet = await _open(tester)
      ..failWith = const api.ConflictException('that name is taken');
    await tester.enterText(_field, 'Den');
    await tester.pump();
    await tester.tap(_save);
    await pumpFrames(tester, frames: 20);

    expect(find.textContaining('Could not rename it'), findsOneWidget);
    expect(find.text('Rename Lobby'), findsWidgets, reason: 'still open');
    expect(sheet.result, isNull);
  });

  testWidgets('a problem with the name shows under it and blocks Save', (
    tester,
  ) async {
    final sheet = await _open(
      tester,
      requireChange: false,
      problem: (name) => name == 'Lobby' ? 'Already taken.' : null,
    );
    expect(find.text('Already taken.'), findsOneWidget);
    await tester.tap(_save);
    await pumpFrames(tester);
    expect(sheet.saved, isEmpty);

    await tester.enterText(_field, 'Den');
    await tester.pump();
    expect(find.text('Already taken.'), findsNothing);
    await tester.tap(_save);
    await pumpFrames(tester, frames: 20);
    expect(sheet.saved, ['Den']);
  });

  testWidgets('a blocked sheet never saves, whatever the name', (tester) async {
    final sheet = await _open(
      tester,
      requireChange: false,
      blocked: 'That file is too large.',
    );
    expect(find.text('That file is too large.'), findsOneWidget);
    await tester.tap(_save);
    await pumpFrames(tester);
    expect(sheet.saved, isEmpty);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('a heading, a close button and a full-width Save at $width', (
      tester,
    ) async {
      final sheet = await _open(tester, width: width);
      expect(
        find.bySemanticsLabel('Rename Lobby'),
        findsWidgets,
        reason: 'the title is announced',
      );
      expect(
        tester.getRect(_save).width,
        moreOrLessEquals(tester.getRect(_field).width, epsilon: 40),
      );

      await tester.tap(find.byTooltip('Close'));
      await pumpFrames(tester, frames: 20);
      expect(find.text('Rename Lobby'), findsNothing);
      expect(sheet.result, isFalse);
    });
  }
}
