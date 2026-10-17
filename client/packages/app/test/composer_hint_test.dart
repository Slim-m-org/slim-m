// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's placeholder text, for the one channel kind whose name is
/// genuinely empty: a thread (see ChannelScreen's `channelName`, `channel?.name
/// ?? ''`), which reused the ordinary "Message #$channelName" hint and
/// rendered a dangling "Message #" with nothing after the hash.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';

import 'features/composer/composer_harness.dart';

const _hintKey = Key('composer-hint');

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  /// shell.md's finding: at the exact width the two-pane rail-plus-content
  /// layout begins, the hint wrapped to a second line and grew the composer
  /// by a full extra line for no content reason.
  testWidgets('the hint never wraps to a second line', (tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        channelName: 'general',
      ),
    );

    final hint = tester.widget<Text>(find.byKey(_hintKey));
    expect(hint.maxLines, 1);
    expect(hint.overflow, TextOverflow.ellipsis);
  });

  testWidgets('a named channel still shows "Message #name"', (tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        channelName: 'general',
      ),
    );

    final hint = tester.widget<Text>(find.byKey(_hintKey));
    expect(hint.textSpan!.toPlainText(), 'Message #general');
  });

  testWidgets('an empty channel name (a thread) drops the hash entirely', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        channelName: '',
      ),
    );

    final hint = tester.widget<Text>(find.byKey(_hintKey));
    expect(hint.textSpan!.toPlainText(), 'Message');
  });

  /// Ties the constant a thread's local channel row is actually stored with
  /// (`providers/threads.dart`) to this behaviour, not just a bare `''`
  /// literal: a non-empty placeholder there was a real bug, rendering
  /// "Message #Thread" for every warm-opened thread.
  testWidgets(
    "a thread's own channel-name constant drops the hash the same way",
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
          channelName: threadChannelName,
        ),
      );

      final hint = tester.widget<Text>(find.byKey(_hintKey));
      expect(hint.textSpan!.toPlainText(), 'Message');
    },
  );

  /// scripts/lib/e2e_labels.py's own `COMPOSER` used to match this hint
  /// text directly, which broke the moment a thread or a DM (both a genuinely
  /// empty channel name) stopped rendering the dangling "Message #" the hint
  /// fix above closes - see PRs #379 and #550, both "e2e was red".
  /// The field carries its own stable name now, independent of the hint
  /// text a channel name can empty out and that typing itself makes vanish.
  testWidgets(
    'the field carries a stable accessible name regardless of channel name',
    (tester) async {
      for (final name in ['general', '']) {
        await tester.pumpWidget(
          composerHarness(
            controller: controller,
            sends: sends,
            platform: TargetPlatform.iOS,
            channelName: name,
          ),
        );
        final semantics = tester.getSemantics(find.byType(TextField));
        expect(semantics.label, contains('Message composer'));
      }
    },
  );

  testWidgets(
    'the accessible name survives once something is typed and the hint disappears',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
          channelName: '',
        ),
      );
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();

      expect(find.byKey(_hintKey), findsNothing);
      final semantics = tester.getSemantics(find.byType(TextField));
      expect(semantics.label, contains('Message composer'));
    },
  );
}
