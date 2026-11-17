// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mic stands in for Send while the composer is empty, and tapping it
/// turns the row into the recording bar until the clip is sent or discarded.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/call_start_yields.dart';
import 'package:slimm_app/src/features/composer/providers/composer_actions.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_action_bar.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_voice_bar.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../support/fake_voice.dart';
import 'voice_recording_test.dart' show FakeActions, FakeCapture;

Future<void> pumpBar(
  WidgetTester tester, {
  required bool canRecord,
  required bool canSend,
  required FakeCapture capture,
  required FakeActions actions,
  List<Override> overrides = const [],
}) async {
  final controller = TextEditingController();
  addTearDown(controller.dispose);
  final focus = FocusNode();
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceCaptureFactoryProvider.overrideWithValue(() => capture),
        composerActionsProvider.overrideWithValue(actions),
        ...overrides,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ComposerActionBar(
              touch: false,
              controller: controller,
              focusNode: focus,
              channelId: 'c1',
              channelName: 'general',
              hasText: canSend,
              canSend: canSend,
              canRecord: canRecord,
              onVoiceSent: (_) {},
              onSend: () async {},
              onTyping: (_) {},
              onOpenActions: () {},
              onPickFile: () {},
              onSendPressed: () {},
              onInsertCode: () {},
              onPickEmoji: () {},
              gifSearchEnabled: false,
              onInsertEmoji: (_) {},
              onStageGif: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Puts the recorder behind the bar on a clock the test moves by hand.
({ProviderContainer container, void Function(Duration) advance}) clocked(
  WidgetTester tester,
) {
  final container = ProviderScope.containerOf(
    tester.element(find.byKey(const Key('composer-action-bar'))),
  );
  var clock = DateTime(2026, 1, 1);
  container.read(voiceRecorderProvider('c1').notifier).now = () => clock;
  return (container: container, advance: (by) => clock = clock.add(by));
}

AppIconButton voiceButton(WidgetTester tester, String label) =>
    tester.widget<AppIconButton>(
      find.byWidgetPredicate(
        (w) => w is AppIconButton && w.semanticLabel == label,
      ),
    );

void main() {
  final record = find.byTooltip('Record a voice message');
  final send = find.byTooltip('Send message');
  final bar = find.byKey(const Key('composer-voice-bar'));

  testWidgets(
    'while the clip finishes, Send waits and Discard still throws it away',
    (tester) async {
      final capture = FakeCapture();
      final actions = FakeActions();
      await pumpBar(
        tester,
        canRecord: true,
        canSend: false,
        capture: capture,
        actions: actions,
      );
      final clock = clocked(tester);
      await tester.pump(ComposerMicButton.wakeDelay);
      await tester.tap(record);
      await tester.pump();
      clock.advance(const Duration(seconds: 3));
      final finish = Completer<void>();
      capture.finishing = finish.future;
      await tester.tap(find.byTooltip('Send voice message'));
      await tester.pump();
      expect(
        clock.container.read(voiceRecorderProvider('c1')).phase,
        VoicePhase.stopping,
      );
      expect(voiceButton(tester, 'Send voice message').onPressed, isNull);
      expect(voiceButton(tester, 'Discard voice message').onPressed, isNotNull);

      await tester.tap(find.byTooltip('Discard voice message'));
      await tester.pump();
      finish.complete();
      await tester.pump();
      expect(bar, findsNothing);
      expect(actions.uploads, isEmpty);
    },
  );

  testWidgets('a phone in a call says why it cannot record, in the bar', (
    tester,
  ) async {
    final capture = FakeCapture();
    await pumpBar(
      tester,
      canRecord: true,
      canSend: false,
      capture: capture,
      actions: FakeActions(),
      overrides: [
        voiceRecordingYieldsToCallProvider.overrideWithValue(true),
        voiceControllerProvider.overrideWith(
          (ref) => FakeVoiceController(
            ref,
            initial: const VoiceState(
              state: VoiceSessionState.connected,
              channelId: 'lounge',
            ),
          ),
        ),
      ],
    );
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(record);
    await tester.pump();
    expect(
      find.descendant(
        of: bar,
        matching: find.text('Leave the call to record a voice message.'),
      ),
      findsOneWidget,
    );
    expect(capture.started, isFalse);
    expect(voiceButton(tester, 'Send voice message').onPressed, isNull);
    expect(
      find.bySemanticsLabel('Send voice message'),
      findsNothing,
      reason: 'a refusal has nothing it could ever send',
    );
  });

  testWidgets('a call starting stops the recording, keeps it and says why', (
    tester,
  ) async {
    final actions = FakeActions();
    await pumpBar(
      tester,
      canRecord: true,
      canSend: false,
      capture: FakeCapture(),
      actions: actions,
    );
    final clock = clocked(tester);
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(record);
    await tester.pump();
    clock.advance(const Duration(seconds: 4));

    await clock.container.read(callStartYieldsProvider).callStarting();
    await tester.pump();

    expect(
      find.descendant(of: bar, matching: find.text('Stopped for a call')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('composer-voice-dot')), findsNothing);
    expect(find.text('0:04'), findsOneWidget);
    await tester.tap(find.byTooltip('Send voice message'));
    await tester.pump();
    await tester.pump();
    expect(actions.uploads, hasLength(1));
  });

  testWidgets('an empty composer offers the mic in place of Send', (
    tester,
  ) async {
    await pumpBar(
      tester,
      canRecord: true,
      canSend: false,
      capture: FakeCapture(),
      actions: FakeActions(),
    );
    expect(record, findsOneWidget);
    expect(send, findsNothing);
  });

  testWidgets('typed text brings Send back', (tester) async {
    await pumpBar(
      tester,
      canRecord: false,
      canSend: true,
      capture: FakeCapture(),
      actions: FakeActions(),
    );
    expect(send, findsOneWidget);
    expect(record, findsNothing);
  });

  testWidgets('tapping the mic records, and discard puts the field back', (
    tester,
  ) async {
    final capture = FakeCapture();
    await pumpBar(
      tester,
      canRecord: true,
      canSend: false,
      capture: capture,
      actions: FakeActions(),
    );
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(record);
    await tester.pump();
    expect(bar, findsOneWidget);
    expect(capture.started, isTrue);
    expect(find.byKey(const Key('composer-voice-dot')), findsOneWidget);
    expect(find.byKey(const Key('composer-action-bar')), findsOneWidget);

    await tester.tap(find.byTooltip('Discard voice message'));
    await tester.pump();
    expect(bar, findsNothing);
    expect(capture.cancelled, isTrue);
    expect(record, findsOneWidget);
  });

  testWidgets('a denied microphone shows the reason inline and can be closed', (
    tester,
  ) async {
    await pumpBar(
      tester,
      canRecord: true,
      canSend: false,
      capture: FakeCapture(allowed: false),
      actions: FakeActions(),
    );
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(record);
    await tester.pump();
    expect(find.byKey(const Key('composer-voice-error')), findsOneWidget);
    expect(
      voiceButton(tester, 'Send voice message').onPressed,
      isNull,
      reason: 'there is nothing to send',
    );
    await tester.tap(find.byTooltip('Discard voice message'));
    await tester.pump();
    expect(bar, findsNothing);
  });

  testWidgets(
    'a fresh mic ignores a press, so a double-click on Send cannot record',
    (tester) async {
      final capture = FakeCapture();
      await pumpBar(
        tester,
        canRecord: true,
        canSend: false,
        capture: capture,
        actions: FakeActions(),
      );
      await tester.tap(record, warnIfMissed: false);
      await tester.pump();
      expect(capture.started, isFalse);
      expect(bar, findsNothing);
      await tester.pump(ComposerMicButton.wakeDelay);
    },
  );
}
