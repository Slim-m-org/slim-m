// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message outlives leaving its channel: a recording or a clip waits
/// in the channel it was made in, and is never posted into another one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/call_start_yields.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_voice_bar.dart';

import 'composer_harness.dart';
import 'voice_recording_test.dart' show FakeCapture;

final _record = find.byTooltip('Record a voice message');
final _sendVoice = find.byTooltip('Send voice message');
final _bar = find.byKey(const Key('composer-voice-bar'));

Finder _inBar(String text) =>
    find.descendant(of: _bar, matching: find.text(text));

/// One app's worth of composers, any of which [show] puts on screen.
class _Screens {
  _Screens(this.tester, {api.SlimmApi Function(Ref)? apiBuilder})
    : _apiBuilder = apiBuilder;

  final WidgetTester tester;
  final api.SlimmApi Function(Ref)? _apiBuilder;
  final controller = TextEditingController();
  final sends = Sends();
  final capture = FakeCapture();
  late final ProviderContainer container;
  DateTime clock = DateTime(2026, 1, 1);

  /// Opens [channelId]'s composer, or none for a screen without one (a voice channel).
  Future<void> show(String? channelId) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        channelId: channelId ?? 'c1',
        mountComposer: channelId != null,
        apiBuilder: _apiBuilder,
        extraOverrides: [
          voiceCaptureFactoryProvider.overrideWithValue(() => capture),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Shows #c1 and starts a voice message there.
  Future<void> recordInC1() async {
    addTearDown(controller.dispose);
    await show('c1');
    container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('composer-action-bar'))),
    );
    container.read(voiceRecorderProvider('c1').notifier).now = () => clock;
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(_record);
    await tester.pump();
  }

  Future<void> sendFromBar() async {
    await tester.tap(_sendVoice);
    await tester.pump();
    await tester.pump();
  }

  List<StagedAttachment> staged(String channelId) =>
      container.read(attachmentStagingProvider(channelId)).items;
}

void main() {
  testWidgets('a voice message that finishes uploading after a channel switch '
      'stays in its own channel', (tester) async {
    final upload = Completer<void>();
    final screens = _Screens(tester, apiBuilder: gatedUploadApi(upload));
    await screens.recordInC1();
    screens.clock = screens.clock.add(const Duration(seconds: 3));
    await tester.tap(_sendVoice);
    await tester.pump();
    expect(find.text('Sending'), findsOneWidget);

    screens.controller.text = 'hello';
    await screens.show('c2');
    upload.complete();
    await tester.pump();
    await tester.pump();

    expect(screens.sends.count, 0, reason: 'nothing is posted into #c2');
    expect(screens.controller.text, 'hello');
    final staged = screens.staged('c1');
    expect(staged.single, isA<UploadedAttachment>());
    expect((staged.single as UploadedAttachment).attachment.id, 'a1');
    expect(screens.staged('c2'), isEmpty);
  });

  testWidgets('a recording left running when a voice channel opens stops for '
      'the call and waits in its own channel', (tester) async {
    final screens = _Screens(tester);
    await screens.recordInC1();
    screens.clock = screens.clock.add(const Duration(seconds: 3));

    await screens.show(null);
    expect(screens.capture.cancelled, isFalse, reason: 'it is still recording');
    screens.clock = screens.clock.add(const Duration(seconds: 2));
    await screens.container.read(callStartYieldsProvider).callStarting();
    expect(screens.capture.stopped, isTrue);

    await screens.show('c2');
    expect(_bar, findsNothing, reason: 'the clip belongs to #c1');
    await screens.show('c1');
    expect(_inBar('Stopped for a call'), findsOneWidget);
    expect(_inBar('0:05'), findsOneWidget);
    await screens.sendFromBar();
    expect(screens.sends.count, 1, reason: 'posted from #c1');
    expect(screens.sends.ids, ['a1']);
  });

  testWidgets('a clip the limit finished is still there on return', (
    tester,
  ) async {
    final screens = _Screens(tester);
    await screens.recordInC1();
    screens.clock = screens.clock.add(kVoiceMaxDuration);
    await tester.pump(kVoiceTick);
    await tester.pump();
    expect(_inBar('5:00 limit'), findsOneWidget);

    await screens.show('c2');
    await screens.show('c1');

    expect(_inBar('5:00 limit'), findsOneWidget);
    await screens.sendFromBar();
    expect(screens.sends.ids, ['a1']);
  });

  testWidgets('discarding a recording kept across channels lets it go', (
    tester,
  ) async {
    final screens = _Screens(tester);
    await screens.recordInC1();
    await screens.show('c2');
    await screens.show('c1');
    expect(find.byKey(const Key('composer-voice-dot')), findsOneWidget);

    await tester.tap(find.byTooltip('Discard voice message'));
    await tester.pump();
    expect(screens.capture.cancelled, isTrue);
    await screens.show('c2');

    expect(
      screens.container.exists(voiceRecorderProvider('c1')),
      isFalse,
      reason: 'nothing is kept once it is thrown away',
    );
    await screens.show('c1');
    expect(_bar, findsNothing);
    expect(_record, findsOneWidget);
  });
}
