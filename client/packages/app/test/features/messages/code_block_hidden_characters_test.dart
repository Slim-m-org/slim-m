// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A code block that hides text-direction or zero-width characters shows them
/// as named markers with a warning, and offers no Run (trojan source,
/// CVE-2021-42574). Payloads are `\u{...}` escapes on purpose: an inline CI
/// gate refuses literal exotic characters in client sources.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/code_block_runner.dart';
import 'package:slimm_app/src/widgets/code_hidden_characters.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

const _runner = api.CodeBlockRunner(
  moduleId: 'code-exec',
  command: 'run',
  language: 'javascript',
);

// The classic access-check trojan: the override reorders what the eye reads.
const _trojan =
    'if (accessLevel != "user\u{202E} \u{2066}// Check if admin\u{2069} \u{2066}") {\n'
    '  grant();\n'
    '}';

Future<void> _pump(WidgetTester tester, String code) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        codeBlockRunnerProvider.overrideWith((ref) async => [_runner]),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: MessageBody(
            content: '```js\n$code\n```',
            knownUsernames: const {},
            messageId: 'm1',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _renderedCode(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((w) => w.text.toPlainText())
    .join('\n');

void main() {
  testWidgets('a trojan-source block shows its hidden characters and no Run', (
    tester,
  ) async {
    await _pump(tester, _trojan);

    final rendered = _renderedCode(tester);
    expect(rendered, contains('<U+202E>'));
    expect(rendered, contains('<U+2066>'));
    expect(rendered, contains('<U+2069>'));
    expect(rendered, isNot(contains('\u{202E}')));
    expect(find.textContaining('hidden characters'), findsOneWidget);
    expect(find.bySemanticsLabel('Run with code-exec'), findsNothing);
  });

  testWidgets('a zero-width space alone is marked and withholds Run', (
    tester,
  ) async {
    await _pump(tester, 'let a\u{200B}b = 1');

    expect(_renderedCode(tester), contains('<U+200B>'));
    expect(find.bySemanticsLabel('Run with code-exec'), findsNothing);
  });

  testWidgets('an ordinary block keeps its Run and shows no warning', (
    tester,
  ) async {
    await _pump(tester, 'let caf\u{e9} = "\u{4e16}\u{754c}";\n\tdone();');

    expect(find.textContaining('hidden characters'), findsNothing);
    expect(find.bySemanticsLabel('Run with code-exec'), findsOneWidget);
  });

  test(
    'markers keep the surrounding roles and the stored text is untouched',
    () {
      const original = 'a\u{202E}b';
      final lines = revealHiddenCodeCharacters([AppCodeLine.plain(original)]);
      final spans = lines.single.spans;
      expect([for (final s in spans) s.text], ['a', '<U+202E>', 'b']);
      expect(spans[1].role, AppCodeRole.hidden);
      expect(spans[0].role, AppCodeRole.plain);
      expect(original.length, 3);
    },
  );

  test('tab, newline and carriage return are ordinary code', () {
    expect(hasHiddenCodeCharacters('a\tb\r\nc'), isFalse);
    expect(hasHiddenCodeCharacters('a\u{7}b'), isTrue);
    expect(hasHiddenCodeCharacters('a\u{200E}b'), isTrue);
    expect(hasHiddenCodeCharacters('a\u{FEFF}b'), isTrue);
  });
}
