// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mic stands in for Send while the composer is empty, and tapping it
/// turns the row into the recording bar until the clip is sent or discarded.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/composer/providers/composer_actions.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_action_bar.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_recording_test.dart' show FakeActions, FakeCapture;

Future<void> pumpBar(
  WidgetTester tester, {
  required bool canRecord,
  required bool canSend,
  required FakeCapture capture,
  required FakeActions actions,
  List<Attachment>? sent,
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
              onVoiceSent: (attachment, _) => sent?.add(attachment),
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

void main() {
  final record = find.byTooltip('Record a voice message');
  final send = find.byTooltip('Send message');
  final bar = find.byKey(const Key('composer-voice-bar'));

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
    await tester.tap(record);
    await tester.pump();
    expect(find.byKey(const Key('composer-voice-error')), findsOneWidget);
    expect(
      tester
          .widget<AppIconButton>(
            find.byWidgetPredicate(
              (w) =>
                  w is AppIconButton && w.semanticLabel == 'Send voice message',
            ),
          )
          .onPressed,
      isNull,
      reason: 'there is nothing to send',
    );
    await tester.tap(find.byTooltip('Discard voice message'));
    await tester.pump();
    expect(bar, findsNothing);
  });
}
