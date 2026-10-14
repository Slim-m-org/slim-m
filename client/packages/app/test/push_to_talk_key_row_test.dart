// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The push-to-talk key is any key a person presses after Change, not one
/// of four letters; Escape backs out, and keys that already mean something
/// while choosing are not taken.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/widgets/push_to_talk_key_row.dart';
import 'package:slimm_design_system/design_system.dart';

Future<List<LogicalKeyboardKey>> _pump(WidgetTester tester) async {
  final picked = <LogicalKeyboardKey>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => PushToTalkKeyRow(
            current: picked.isEmpty ? LogicalKeyboardKey.keyV : picked.last,
            onChanged: (key) => setState(() => picked.add(key)),
          ),
        ),
      ),
    ),
  );
  return picked;
}

void main() {
  testWidgets('Change takes the next key pressed, even a function key', (
    tester,
  ) async {
    final picked = await _pump(tester);
    expect(find.text('V'), findsOneWidget);

    await tester.tap(find.text('Change'));
    await tester.pump();
    expect(find.text('Press a key, or Escape to cancel'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();
    expect(picked, [LogicalKeyboardKey.f8]);
    expect(find.text('Change'), findsOneWidget, reason: 'back to the row');
  });

  testWidgets('Escape cancels without changing the key', (tester) async {
    final picked = await _pump(tester);
    await tester.tap(find.text('Change'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(picked, isEmpty);
    expect(find.text('V'), findsOneWidget);
  });

  testWidgets('Tab and Enter are not taken as the key', (tester) async {
    final picked = await _pump(tester);
    await tester.tap(find.text('Change'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(picked, isEmpty);
    expect(find.text('Press a key, or Escape to cancel'), findsOneWidget);
  });

  test('a saved key outside the old four letters loads back', () async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.push_to_talk_key_id': LogicalKeyboardKey.backquote.keyId,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(voiceSettingsControllerProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(voiceSettingsControllerProvider).pushToTalkKey,
      LogicalKeyboardKey.backquote,
    );
  });
}
