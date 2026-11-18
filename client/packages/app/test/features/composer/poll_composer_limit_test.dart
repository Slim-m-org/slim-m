// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A poll's question and options are capped in code points, the unit the
/// server counts, and say their count as the cap nears.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/poll_composer_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

/// One visible family emoji, seven code points.
const _family = '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}';

void main() {
  testWidgets('a question of emoji stops at the server cap, counted', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPollComposerSheet(context, 'c-general'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await pumpFrames(tester, frames: 30);

    final question = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is AppInput && w.placeholder == 'Ask a question',
      ),
      matching: find.byWidgetPredicate((w) => w is EditableText),
    );
    await tester.enterText(question, _family * 100);
    await tester.pump();

    final typed = tester.widget<EditableText>(question).controller.text;
    expect(typed.runes.length, api.InputLimits.pollQuestion);
    expect(
      find.text(
        '${api.InputLimits.pollQuestion}/${api.InputLimits.pollQuestion}',
      ),
      findsOneWidget,
    );
  });
}
