// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `docs/IMPLIED-GAPS.md` item 8's own unchecked worry: does copying selected
/// message text actually round-trip the visible content of a mention chip,
/// an inline code span and a spoiler, all three of which render as
/// `WidgetSpan`s (`message_text.dart`) rather than plain `TextSpan`s?
///
/// A presence check (`find.byType(SelectionArea)`, as
/// `transcript_selection_test.dart` already does) cannot answer this: it
/// proves the wrapper is mounted, not that a `WidgetSpan`'s child actually
/// participates in the selection `SelectionArea` establishes. This drives a
/// real `selectAll()` plus a real copy through `SelectableRegionState`'s own
/// public API, the same primitive a real Ctrl+A/Ctrl+C goes through, and
/// reads the actual copied plain text back off a faked clipboard channel.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_app/src/features/messages/widgets/transcript_selection.dart';
import 'package:slimm_design_system/design_system.dart';

/// Drives the real `selectAll` + copy path a Ctrl+A/Ctrl+C would, through
/// `SelectableRegionState`'s own public API rather than reaching for its
/// private selection delegate, and reads back whatever actually landed on
/// the platform clipboard.
Future<String?> _selectAllAndCopy(WidgetTester tester) async {
  final state = tester.state<SelectionAreaState>(find.byType(SelectionArea));
  state.selectableRegion.selectAll();
  await tester.pump();
  // ignore: deprecated_member_use
  state.selectableRegion.copySelection(SelectionChangedCause.keyboard);
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  return data?.text;
}

/// The test binding ships no default handler for `Clipboard.setData`/
/// `getData`, so an unmocked call awaits a platform response that never
/// arrives and the test hangs rather than fails - this stands in with a
/// plain in-memory clipboard, the same shape `TestDefaultBinaryMessengerBinding`
/// callers elsewhere in this client already hand-roll for a native channel.
String? _clipboardText;

void _installFakeClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            _clipboardText = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return _clipboardText == null ? null : {'text': _clipboardText};
          case 'Clipboard.hasStrings':
            return {'value': _clipboardText != null};
          default:
            return null;
        }
      });
}

void main() {
  setUp(() {
    _clipboardText = null;
    _installFakeClipboard();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pump(WidgetTester tester, String content) => tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(
        Brightness.dark,
        AppTokens.dark,
      ).copyWith(platform: TargetPlatform.linux),
      home: Scaffold(
        body: TranscriptSelection(
          child: MessageBody(content: content, knownUsernames: const {'alice'}),
        ),
      ),
    ),
  );

  testWidgets('a plain mention round-trips through select-all and copy', (
    tester,
  ) async {
    await pump(tester, 'thanks @alice for the fix');

    final copied = await _selectAllAndCopy(tester);
    expect(copied, contains('@alice'));
    expect(copied, contains('thanks'));
    expect(copied, contains('for the fix'));
  });

  testWidgets('an inline code span round-trips through select-all and copy', (
    tester,
  ) async {
    await pump(tester, 'run `cargo test --all` before pushing');

    final copied = await _selectAllAndCopy(tester);
    expect(copied, contains('cargo test --all'));
    expect(copied, contains('run'));
    expect(copied, contains('before pushing'));
  });

  testWidgets('a revealed spoiler round-trips through select-all and copy', (
    tester,
  ) async {
    await pump(tester, 'the ending is ||they were the killer all along||');
    await tester.tap(find.bySemanticsLabel(RegExp('Hidden spoiler')));
    await tester.pump();

    final copied = await _selectAllAndCopy(tester);
    expect(copied, contains('they were the killer all along'));
  });

  testWidgets(
    'an unrevealed spoiler does not leak its text through select-all',
    (tester) async {
      await pump(tester, 'the ending is ||they were the killer all along||');

      final copied = await _selectAllAndCopy(tester);
      expect(
        copied,
        isNot(contains('they were the killer all along')),
        reason:
            'a spoiler still hidden on screen must not be readable by '
            'selecting past it, or the tap-to-reveal affordance is theatre',
      );
    },
  );
}
