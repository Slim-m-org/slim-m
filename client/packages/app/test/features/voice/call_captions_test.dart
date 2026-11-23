// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Captions and the live transcript tab (decision 0113): shown only while the
/// server transcribes the call for someone who may read it, only lines said
/// after the strip opened, cleared once the call goes quiet.
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
import 'package:slimm_app/src/features/voice/widgets/captions_button.dart';
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

  void say(int seq) =>
      state = state.copyWith(lines: [...state.lines, _line(seq)]);
}

/// A running call whose first page left more behind it, read on after the strip opens.
class _Paged extends _Lines {
  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    return CallTranscriptModel(
      lines: [_line(1)],
      loaded: true,
      ongoing: true,
      hasMore: true,
    );
  }

  void readOn(Iterable<int> seqs) => state = state.copyWith(
    lines: [...state.lines, for (final seq in seqs) _line(seq)],
    hasMore: false,
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

List<Override> _overrides({
  api.CallAudioState? session,
  int bits = Perm.viewChannel | Perm.viewTranscripts,
  bool captionsOn = true,
  CallTranscriptController Function()? transcript,
}) => [
  callAudioProvider.overrideWith(() => _Audio(session)),
  channelPermissionsProvider.overrideWith((ref, id) async => bits),
  callTranscriptProvider.overrideWith(transcript ?? _Lines.new),
  userProfileProvider.overrideWith((ref, id) async => null),
  if (captionsOn) voiceSettingsControllerProvider.overrideWith(_CaptionsOn.new),
];

Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<Override> overrides,
) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                if (canUseCaptions(ref, 'voice-1')) const CaptionsButton(),
                const CallCaptionsStrip(channelId: 'voice-1'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  testWidgets('lines read after the strip opened are history, not captions', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      _overrides(session: _session(), transcript: _Paged.new),
    );
    final lines =
        container.read(callTranscriptProvider('t1').notifier) as _Paged;

    lines.readOn([2, 3, 4]);
    await tester.pump();
    expect(find.textContaining('line 4'), findsNothing);

    lines.say(5);
    await tester.pump();
    expect(find.textContaining('line 5'), findsOneWidget);
  });

  testWidgets('only lines said after the strip opened show, then clear', (
    tester,
  ) async {
    final container = await _pump(tester, _overrides(session: _session()));
    expect(find.byKey(callCaptionsKey), findsOneWidget);
    expect(find.textContaining('line 1'), findsNothing);

    final lines =
        container.read(callTranscriptProvider('t1').notifier) as _Lines;
    for (final seq in [2, 3, 4, 5]) {
      lines.say(seq);
    }
    await tester.pump();
    expect(find.textContaining('line 2'), findsNothing, reason: 'three fit');
    for (final seq in [3, 4, 5]) {
      expect(find.textContaining('line $seq'), findsOneWidget);
    }

    await tester.pump(captionHold - const Duration(seconds: 1));
    lines.say(6);
    await tester.pump(const Duration(seconds: 2));
    expect(
      find.textContaining('line 6'),
      findsOneWidget,
      reason: 'a newer line keeps them',
    );

    await tester.pump(captionHold);
    expect(find.textContaining('line'), findsNothing);
    expect(
      find.byKey(callCaptionsKey),
      findsOneWidget,
      reason: 'the height stays',
    );
  });

  testWidgets('the strip keeps one height whatever it holds', (tester) async {
    final container = await _pump(tester, _overrides(session: _session()));
    final empty = tester.getSize(find.byKey(callCaptionsKey));
    final lines =
        container.read(callTranscriptProvider('t1').notifier) as _Lines;
    lines.say(2);
    await tester.pump();
    expect(tester.getSize(find.byKey(callCaptionsKey)), empty);
  });

  for (final (why, overrides) in [
    ('no transcript runs', _overrides()),
    (
      'a module hears the call',
      _overrides(session: _session(transcriptId: null)),
    ),
    ('people are still asked', _overrides(session: _session(on: false))),
    (
      'the member may not read transcripts',
      _overrides(session: _session(), bits: Perm.viewChannel),
    ),
  ]) {
    testWidgets('no captions and no button when $why', (tester) async {
      final container = await _pump(tester, overrides);
      expect(find.byKey(callCaptionsKey), findsNothing);
      expect(find.byTooltip('Show captions'), findsNothing);
      expect(container.read(liveCallTranscriptIdProvider('voice-1')), isNull);
    });
  }

  testWidgets('the button turns captions on, off by default', (tester) async {
    await _pump(tester, _overrides(session: _session(), captionsOn: false));
    expect(find.byKey(callCaptionsKey), findsNothing);
    await tester.tap(find.byTooltip('Show captions'));
    await tester.pump();
    expect(find.byKey(callCaptionsKey), findsOneWidget);
    expect(find.byTooltip('Hide captions'), findsOneWidget);
  });
}
