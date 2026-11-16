// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message's controls off the pointer: Tab and the arrow keys reach
/// the speed and the playhead, a screen reader gets a button and a slider, and
/// a right-click or long press offers to save the clip or copy its words.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_player_fakes.dart';

class _RecordingDownloads extends DownloadsController {
  final started = <String>[];

  @override
  List<DownloadTask> build() => const [];

  @override
  Future<void> start(Attachment attachment, {bool original = false}) async =>
      started.add(attachment.id);
}

bool _focusIsIn(Finder target) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return find
      .descendant(
        of: target,
        matching: find.byElementPredicate((e) => e == focused),
      )
      .evaluate()
      .isNotEmpty;
}

Future<void> _tabTo(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 8 && !_focusIsIn(target); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(_focusIsIn(target), isTrue, reason: 'Tab never reached it');
}

void main() {
  late FakePlayer player;

  testWidgets('Tab reaches the speed, and Enter changes it without playing', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    await _tabTo(tester, find.byKey(const Key('voice-player-speed')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('1.5x').hitTestable(), findsOneWidget);
    expect(player.log, isEmpty);
  });

  testWidgets('Enter on Play keeps focus on the control while the clip loads', (
    tester,
  ) async {
    final gate = Completer<Uint8List>();
    player = await pumpVoicePlayers(tester, [
      voiceMessage('a'),
    ], slowBytes: gate.future);
    final control = find.byTooltip('Play');
    await _tabTo(tester, control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is AppSpinner), findsOneWidget);
    expect(_focusIsIn(find.byKey(const Key('voice-player-a'))), isTrue);
    expect(_focusIsIn(find.byTooltip('Play')), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    gate.complete(Uint8List.fromList([1, 2, 3, 4]));
    await tester.pump();
    await tester.pump();
    expect(player.log.where((l) => l.startsWith('play')), hasLength(1));
    expect(_focusIsIn(find.byTooltip('Pause')), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(player.log.last, 'pause');
  });

  testWidgets('arrow keys on the waveform move the playhead five seconds', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    await _tabTo(tester, find.byKey(const Key('voice-player-wave')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(player.log.last, 'seek 5000');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(player.log.last, 'seek 0');
  });

  testWidgets('a screen reader gets a speed button and a position slider', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    expect(
      tester.getSemantics(find.byKey(const Key('voice-player-speed'))),
      isSemantics(
        label: 'Playback speed 1x',
        isButton: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();
    final slider = find.bySemanticsLabel('Voice message position');
    expect(
      tester.getSemantics(slider),
      isSemantics(
        isSlider: true,
        value: '0:00 of 0:40',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    tester.semantics.increase(find.semantics.byLabel('Voice message position'));
    await tester.pump();
    expect(player.log.last, 'seek 5000');
    semantics.dispose();
  });

  testWidgets('a right-click saves the voice message or copies its words', (
    tester,
  ) async {
    final downloads = _RecordingDownloads();
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    player = await pumpVoicePlayers(
      tester,
      [
        voiceMessage(
          'a',
          transcript: const VoiceTranscript(
            status: VoiceTranscriptStatus.ready,
            text: 'meet me at the lighthouse',
          ),
        ),
      ],
      extra: [downloadsProvider.overrideWith(() => downloads)],
    );
    final chip = find.byKey(const ValueKey('voice-player-a'));
    await tester.tap(chip, buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Copy transcript'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(copied, ['meet me at the lighthouse']);
    await tester.tap(chip, buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save voice message'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(downloads.started, ['a']);
  });

  testWidgets('a Space with transcripts off has no transcript to copy', (
    tester,
  ) async {
    player = await pumpVoicePlayers(
      tester,
      [
        voiceMessage(
          'a',
          transcript: const VoiceTranscript(
            status: VoiceTranscriptStatus.ready,
            text: 'meet me at the lighthouse',
          ),
        ),
      ],
      extra: [
        serverInfoProvider.overrideWith(
          (ref) => const Version(
            name: 'slim-m',
            version: '1',
            protocol: 1,
            transcribeVoiceMessages: false,
          ),
        ),
      ],
    );
    expect(find.text('meet me at the lighthouse'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('voice-player-a')),
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Save voice message'), findsOneWidget);
    expect(find.text('Copy transcript'), findsNothing);
  });

  testWidgets('without words heard the menu has nothing to copy', (
    tester,
  ) async {
    player = await pumpVoicePlayers(tester, [voiceMessage('a')]);
    await tester.tap(
      find.byKey(const ValueKey('voice-player-a')),
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Save voice message'), findsOneWidget);
    expect(find.text('Copy transcript'), findsNothing);
  });
}
