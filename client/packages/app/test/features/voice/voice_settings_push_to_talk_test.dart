// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the push-to-talk section: enabling it and choosing a key both
/// persist, and both rows carry their own real accessible name against the
/// dumped tree. What holding and releasing the key actually does to the
/// microphone is `push_to_talk_test.dart`; reaching the key event itself,
/// and the composer-focus guard, is `push_to_talk_listener_test.dart`.
///
/// `voice_settings_camera_test.dart`'s own shape - a new preference gets its
/// own file rather than growing `voice_settings_screen_test.dart` again.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show AppLog, LogRecord, LogSink;
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_settings_screen_harness.dart';

class _Records implements LogSink {
  final messages = <String>[];

  @override
  void write(LogRecord record) => messages.add(record.message);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppLog.install(null));

  testWidgets('every change to push-to-talk leaves a log line naming why', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.push_to_talk_enabled': true,
    });
    final records = _Records();
    AppLog.install(records);
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
    );
    await tester.pumpAndSettle();
    expect(
      records.messages.where((m) => m.contains('read from stored settings')),
      hasLength(1),
    );

    final pttToggle = find.byWidgetPredicate(
      (w) => w is AppToggle && w.semanticLabel == 'Push-to-talk',
    );
    await tester.scrollUntilVisible(
      pttToggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(pttToggle);
    await tester.pumpAndSettle();
    expect(
      records.messages.where((m) => m.contains('off by the settings toggle')),
      hasLength(1),
    );
  });

  testWidgets('turning on push-to-talk persists it', (tester) async {
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
    );
    await tester.pumpAndSettle();

    final pttToggle = find.byWidgetPredicate(
      (w) => w is AppToggle && w.semanticLabel == 'Push-to-talk',
    );
    await tester.scrollUntilVisible(
      pttToggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(pttToggle);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('slimm.voice.push_to_talk_enabled'), isTrue);
  });

  testWidgets('the key picker is hidden until push-to-talk is on', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
    );
    await tester.pumpAndSettle();

    expect(find.text('V'), findsNothing);

    final pttToggle = find.byWidgetPredicate(
      (w) => w is AppToggle && w.semanticLabel == 'Push-to-talk',
    );
    await tester.scrollUntilVisible(
      pttToggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(pttToggle);
    await tester.pumpAndSettle();

    expect(find.text('V'), findsOneWidget);
  });

  testWidgets('picking a push-to-talk key persists its keyId', (tester) async {
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
    );
    await tester.pumpAndSettle();

    final pttToggle = find.byWidgetPredicate(
      (w) => w is AppToggle && w.semanticLabel == 'Push-to-talk',
    );
    await tester.scrollUntilVisible(
      pttToggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(pttToggle);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Change'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt('slimm.voice.push_to_talk_key_id'),
      LogicalKeyboardKey.keyC.keyId,
    );
  });

  testWidgets(
    'the push-to-talk toggle and the key picker both carry their own real '
    'accessible name, checked against the dumped tree rather than assumed',
    (tester) async {
      final semantics = tester.ensureSemantics();
      SharedPreferences.setMockInitialValues({
        'slimm.voice.push_to_talk_enabled': true,
      });

      await tester.pumpWidget(
        wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
      );
      await tester.pumpAndSettle();

      final pttToggle = find.byWidgetPredicate(
        (w) => w is AppToggle && w.semanticLabel == 'Push-to-talk',
      );
      await tester.scrollUntilVisible(
        pttToggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final toggleNode = tester.getSemantics(
        find.bySemanticsLabel('Push-to-talk'),
      );
      expect(toggleNode.label, contains('Push-to-talk'));
      expect(
        toggleNode.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );

      final keyCap = find.bySemanticsLabel(RegExp('Push-to-talk key: V'));
      expect(keyCap, findsOneWidget);
      expect(find.text('Change'), findsOneWidget);

      semantics.dispose();
    },
  );
}
