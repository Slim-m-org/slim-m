// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The captions strip's geometry: the newest line is whole and inside the strip,
/// starts with its speaker, and a short window keeps two lines.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/call_audio.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/live_call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_captions_strip.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:shared_preferences/shared_preferences.dart';

api.CallAudioState _session({String? transcriptId = 't1', bool on = true}) =>
    api.CallAudioState(
      moduleId: api.CallAudioState.serverConsumerId,
      moduleName: 'Call transcript',
      purpose: 'Writes down what is said.',
      keeps: 'Each line.',
      isOn: on,
      askedBy: '',
      included: const ['nick'],
      pending: const [],
      expiresAtMs: 4102444800000,
      full: false,
      always: true,
      transcriptId: transcriptId,
    );

class _Audio extends CallAudioController {
  _Audio(this._state);

  final api.CallAudioState? _state;

  @override
  CallAudioModel build(String arg) {
    channelId = arg;
    return CallAudioModel(status: api.CallAudioStatus(session: _state));
  }
}

/// A transcript whose lines the test adds by hand.
class _Lines extends CallTranscriptController {
  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    return CallTranscriptModel(lines: [_line(1)], loaded: true, ongoing: true);
  }

  void say(int seq, String text) => state = state.copyWith(
    lines: [
      ...state.lines,
      api.TranscriptLine(seq: seq, speakerId: 'kiki', at: seq, text: text),
    ],
  );
}

api.TranscriptLine _line(int seq) =>
    api.TranscriptLine(seq: seq, speakerId: 'kiki', at: seq, text: 'line $seq');

class _CaptionsOn extends VoiceSettingsController {
  _CaptionsOn(super.ref);

  @override
  set state(VoiceSettingsState value) =>
      super.state = value.copyWith(showCaptions: true);
}

List<Override> _overrides() => [
  callAudioProvider.overrideWith(() => _Audio(_session())),
  channelPermissionsProvider.overrideWith(
    (ref, id) async => Perm.viewChannel | Perm.viewTranscripts,
  ),
  callTranscriptProvider.overrideWith(_Lines.new),
  userProfileProvider.overrideWith((ref, id) async => null),
  voiceSettingsControllerProvider.overrideWith(_CaptionsOn.new),
];

Future<_Lines> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: _overrides());
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: CallCaptionsStrip(channelId: 'voice-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container.read(callTranscriptProvider('t1').notifier) as _Lines;
}

const _long =
    'Yes, the second one failed on the lint step, I think it is the new rule about one line comments in the tests.';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  void expectWhole(WidgetTester tester, int seq) {
    final strip = tester.getRect(find.byKey(callCaptionsKey));
    final line = tester.getRect(find.byKey(ValueKey('caption-$seq')));
    expect(strip.contains(line.topLeft), isTrue, reason: '$line in $strip');
    expect(strip.contains(line.bottomRight), isTrue, reason: '$line in $strip');
  }

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      'long lines keep the newest whole, with its speaker, at $size',
      (tester) async {
        final lines = await _pump(tester, size);
        for (final seq in [2, 3, 4]) {
          lines.say(seq, _long);
        }
        await tester.pump();
        expectWhole(tester, 4);
        final shown = [
          for (final seq in [2, 3, 4])
            if (find.byKey(ValueKey('caption-$seq')).evaluate().isNotEmpty) seq,
        ];
        expect(shown, isNotEmpty);
        for (final seq in shown) {
          expectWhole(tester, seq);
          final text = tester.widget<Text>(
            find.byKey(ValueKey('caption-$seq')),
          );
          expect(text.textSpan!.toPlainText(), startsWith('Someone: '));
        }
      },
    );
  }

  testWidgets('a tall window keeps three lines', (tester) async {
    await _pump(tester, const Size(390, 844));
    expect(tester.getSize(find.byKey(callCaptionsKey)).height, greaterThan(78));
  });

  testWidgets('a short window keeps the strip to two lines', (tester) async {
    await _pump(tester, const Size(844, 390));
    expect(tester.getSize(find.byKey(callCaptionsKey)).height, lessThan(66));
  });
}
