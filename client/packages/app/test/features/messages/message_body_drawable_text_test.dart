// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message body and its one-line preview draw at most three combining
/// marks on a letter, so a zalgo stack cannot paint over the rows around it,
/// and no bidi override, so an older message cannot reverse a filename.
/// Payloads are `\u{...}` escapes: a CI gate refuses literal exotic characters.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show kMaxMarksPerBase;
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_app/src/message_preview.dart';
import 'package:slimm_design_system/design_system.dart';

const _zalgo =
    'h\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}i';

int _longestStack(String text) {
  var run = 0;
  var longest = 0;
  for (final c in text.runes) {
    run = c >= 0x0300 && c <= 0x036F ? run + 1 : 0;
    if (run > longest) longest = run;
  }
  return longest;
}

Future<String> _rendered(WidgetTester tester, String content) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: MessageBody(content: content, knownUsernames: const {}),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester
      .widgetList<RichText>(find.byWidgetPredicate((w) => w is RichText))
      .map((w) => w.text.toPlainText())
      .join('\n');
}

void main() {
  testWidgets('a zalgo message draws its stacks capped', (tester) async {
    final text = await _rendered(tester, '**$_zalgo** and $_zalgo');
    expect(text, contains('h\u{0301}\u{0302}\u{0303}i'));
    expect(_longestStack(text), kMaxMarksPerBase);
  });

  testWidgets('an override cannot reverse a filename in a message', (
    tester,
  ) async {
    final text = await _rendered(tester, 'open evil\u{202E}txt.exe');
    expect(text, contains('eviltxt.exe'));
    expect(text, isNot(contains('\u{202E}')));
  });

  test('a preview line is capped and loses overrides too', () {
    final preview = plainPreview('$_zalgo evil\u{202D}x');
    expect(_longestStack(preview), kMaxMarksPerBase);
    expect(preview, endsWith('evilx'));
  });
}
