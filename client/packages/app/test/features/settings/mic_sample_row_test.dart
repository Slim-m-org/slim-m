// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting mic sample row: absent without the native chain, a
/// countdown while it records, the saved name, and failures shown inline.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/mic_sample_controller.dart';
import 'package:slimm_app/src/features/settings/widgets/mic_sample_row.dart';
import 'package:slimm_app/src/features/voice/providers/mic_preview.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

class _Tap implements MicSampleSource {
  _Tap({this.silent = false});

  final bool silent;

  @override
  Future<void> open(String? deviceId) async {}

  @override
  Future<void> start(int seconds) async {}

  @override
  Future<MicSampleChunk> take() async => MicSampleChunk(
    pcm: silent ? Uint8List(0) : Uint8List(kMicSampleRateHz ~/ 5 * 2),
  );

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

class _Harness {
  final saved = <(String, int)>[];
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool supported = true,
  bool inCall = false,
  bool silent = false,
}) async {
  final harness = _Harness();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        micSampleSupportedProvider.overrideWithValue(supported),
        micPreviewBlockedProvider.overrideWithValue(inCall),
        micSampleClockProvider.overrideWithValue(() => DateTime(2026, 11, 2)),
        micSampleRecorderFactoryProvider.overrideWithValue(
          () => MicSampleRecorder(
            source: _Tap(silent: silent),
            seconds: 3,
            interval: const Duration(milliseconds: 200),
            stallTimeout: const Duration(seconds: 1),
          ),
        ),
        micSampleSaverProvider.overrideWithValue((name, wav) async {
          harness.saved.add((name, wav.length));
          return true;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: MicSampleRow()),
      ),
    ),
  );
  return harness;
}

void main() {
  testWidgets('is absent where the capture chain cannot be tapped', (
    tester,
  ) async {
    await _pump(tester, supported: false);
    expect(find.text('Record a mic sample'), findsNothing);
  });

  testWidgets('records nothing until Record is pressed', (tester) async {
    await _pump(tester);
    expect(find.text('Record a mic sample'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);
    expect(find.textContaining('s left'), findsNothing);
  });

  testWidgets('counts down while recording, then names the saved file', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await tester.tap(find.text('Record'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Talk, then chew, swallow and type.'), findsOneWidget);
    expect(find.text('3 s left'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('2 s left'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('s left'), findsNothing);
    expect(find.textContaining('Saved as mic-sample-'), findsOneWidget);
    expect(harness.saved, hasLength(1));
    expect(harness.saved.single.$1, matches(r'^mic-sample-\w+-2026-11-02-'));
    expect(harness.saved.single.$2, 44 + 3 * kMicSampleRateHz * 2);
  });

  testWidgets('Stop ends the recording without saving or an error', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await tester.tap(find.text('Record'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Stop'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(harness.saved, isEmpty);
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Recording stopped.'), findsNothing);
  });

  testWidgets('a silent microphone shows an inline error, not a toast', (
    tester,
  ) async {
    await _pump(tester, silent: true);
    await tester.tap(find.text('Record'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('The microphone gave no audio.'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('is off during a call, which owns the microphone', (
    tester,
  ) async {
    final harness = await _pump(tester, inCall: true);
    expect(find.text('Leave the call to record.'), findsOneWidget);
    await tester.tap(find.text('Record'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('s left'), findsNothing);
    expect(harness.saved, isEmpty);
  });
}
