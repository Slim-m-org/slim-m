// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message still uploading when the user opens another channel is
/// never posted there: it waits, staged, in the channel it was recorded in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_voice_bar.dart';

import 'composer_harness.dart';
import 'voice_recording_test.dart' show FakeCapture;

void main() {
  testWidgets('a voice message that finishes uploading after a channel switch '
      'stays in its own channel', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final sends = Sends();
    final upload = Completer<void>();
    final capture = FakeCapture();
    Widget at(String channelId) => composerHarness(
      controller: controller,
      sends: sends,
      platform: TargetPlatform.linux,
      channelId: channelId,
      apiBuilder: gatedUploadApi(upload),
      extraOverrides: [
        voiceCaptureFactoryProvider.overrideWithValue(() => capture),
      ],
    );

    await tester.pumpWidget(at('c1'));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('composer-action-bar'))),
    );
    var clock = DateTime(2026, 1, 1);
    container.read(voiceRecorderProvider('c1').notifier).now = () => clock;
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(find.byTooltip('Record a voice message'));
    await tester.pump();
    clock = clock.add(const Duration(seconds: 3));
    await tester.tap(find.byTooltip('Send voice message'));
    await tester.pump();
    expect(find.text('Sending'), findsOneWidget);

    controller.text = 'hello';
    await tester.pumpWidget(at('c2'));
    await tester.pump();
    upload.complete();
    await tester.pump();
    await tester.pump();

    expect(sends.count, 0, reason: 'nothing is posted into #c2');
    expect(controller.text, 'hello');
    final staged = container.read(attachmentStagingProvider('c1')).items;
    expect(staged.single, isA<UploadedAttachment>());
    expect((staged.single as UploadedAttachment).attachment.id, 'a1');
    expect(container.read(attachmentStagingProvider('c2')).items, isEmpty);
  });
}
