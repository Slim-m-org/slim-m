// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The create sheet takes one submit: a second Enter while it closes is ignored.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/name_entry_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/async_wait.dart';

void main() {
  testWidgets('a second Enter while the sheet closes creates nothing more', (
    tester,
  ) async {
    final created = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => AppButton(
              label: 'Open',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => NameEntrySheet(
                  noun: 'channel',
                  title: 'New channel',
                  onCreate: (name) async {
                    created.add(name);
                    return null;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await pumpFrames(tester, frames: 20);

    await tester.enterText(
      find.byWidgetPredicate((w) => w is EditableText),
      'den',
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Creating...'), findsOneWidget, reason: 'still closing');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester, frames: 20);

    expect(created, ['den']);
  });
}
