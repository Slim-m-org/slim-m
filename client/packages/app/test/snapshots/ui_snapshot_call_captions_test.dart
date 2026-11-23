// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Captions in the real call shell at every device shape, both themes: the
/// strip sits under the tiles and the share and above the dock, and nothing
/// overflows. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/call_audio.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_text_tab.dart';
import 'package:slimm_app/src/features/voice/screens/voice_in_call.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_surface.dart';
import 'package:slimm_app/src/features/voice/widgets/transcript_line_row.dart';
import 'package:slimm_app/src/features/voice/widgets/call_captions_strip.dart';

import '../features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController, connectedCallState, gridCallState;
import '../ui_snapshot_support.dart';

class _Transcribing extends CallAudioController {
  @override
  CallAudioModel build(String arg) {
    channelId = arg;
    return const CallAudioModel(
      status: api.CallAudioStatus(
        session: api.CallAudioState(
          moduleId: api.CallAudioState.serverConsumerId,
          moduleName: 'Call transcript',
          purpose: 'Writes down what is said.',
          keeps: 'Each line.',
          isOn: true,
          askedBy: '',
          included: ['user-nick', 'user-ada', 'user-bob'],
          pending: [],
          expiresAtMs: 4102444800000,
          full: false,
          always: true,
          transcriptId: 't-live',
        ),
      ),
    );
  }
}

api.TranscriptLine _line(int seq, String speaker, String text) =>
    api.TranscriptLine(
      seq: seq,
      speakerId: speaker,
      at: seq * 1000,
      text: text,
    );

/// One line said before the strip opened, then three said while it shows.
class _Speaking extends CallTranscriptController {
  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    final said = [_line(1, 'user-bob', 'Before the captions came on.')];
    unawaited(
      Future<void>.microtask(
        () => state = state.copyWith(
          lines: [
            ...said,
            _line(2, 'user-ada', 'Can everyone see the build list?'),
            _line(
              3,
              'user-bob',
              'Yes, the second one failed on the lint step, I think it is the new rule about one line comments.',
            ),
            _line(4, 'user-nick', 'I will fix it after this.'),
          ],
        ),
      ),
    );
    return CallTranscriptModel(lines: said, loaded: true, ongoing: true);
  }
}

class _CaptionsOn extends VoiceSettingsController {
  _CaptionsOn(super.ref);

  @override
  set state(VoiceSettingsState value) =>
      super.state = value.copyWith(showCaptions: true);
}

const _shapes = [
  'phone-portrait',
  'phone-landscape',
  'tablet-portrait',
  'desktop-narrow',
  'desktop',
  'laptop-1280',
];

void _expectClear(
  WidgetTester tester,
  Rect captions,
  Finder other,
  String what,
) {
  for (var i = 0; i < other.evaluate().length; i++) {
    final rect = tester.getRect(other.at(i));
    expect(
      captions.overlaps(rect),
      isFalse,
      reason: 'captions $captions cover $what $rect',
    );
  }
}

Future<void> _expectBelowStageAboveDock(WidgetTester tester) async {
  final captions = tester.getRect(find.byKey(callCaptionsKey));
  expect(find.textContaining('the build list'), findsOneWidget);
  expect(
    find.textContaining('Before the captions'),
    findsNothing,
    reason: 'a line said before the strip opened is no caption',
  );
  _expectClear(tester, captions, find.byKey(voiceCallDockKey), 'the dock');
  for (final id in ['user-nick', 'user-ada', 'user-bob']) {
    _expectClear(tester, captions, find.byKey(ValueKey('tile-$id')), id);
    _expectClear(
      tester,
      captions,
      find.byKey(ValueKey('share-stage-$id')),
      "$id's share",
    );
  }
}

void main() {
  setUpAll(loadRealFonts);

  for (final shape in _shapes) {
    for (final (name, call) in [
      ('share', connectedCallState),
      ('grid', gridCallState),
    ]) {
      testWidgets('captions under a $name call at $shape', (tester) async {
        await renderSurfaceThemes(
          tester,
          '/channels/c-main',
          shape,
          const ['dark', 'light'],
          (t) => 'voice-in-call-captions-$name-$shape-$t',
          overrides: [
            voiceControllerProvider.overrideWith(
              (ref) => SnapshotVoiceController(ref, call),
            ),
            callAudioProvider.overrideWith(_Transcribing.new),
            callTranscriptProvider.overrideWith(_Speaking.new),
            channelPermissionsProvider.overrideWith((ref, id) async => -1),
            voiceSettingsControllerProvider.overrideWith(_CaptionsOn.new),
          ],
          afterSettle: _expectBelowStageAboveDock,
        );
      });
    }
  }

  for (final shape in ['phone-portrait', 'laptop-1280']) {
    testWidgets('the live transcript tab at $shape', (tester) async {
      await renderSurfaceThemes(
        tester,
        '/channels/c-main',
        shape,
        const ['dark', 'light'],
        (t) => 'voice-in-call-live-transcript-$shape-$t',
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => SnapshotVoiceController(ref, gridCallState),
          ),
          callAudioProvider.overrideWith(_Transcribing.new),
          callTranscriptProvider.overrideWith(_Speaking.new),
          channelPermissionsProvider.overrideWith((ref, id) async => -1),
          voiceChatPaneVisibleProvider.overrideWith((ref) => true),
          voiceTextTabProvider.overrideWith((ref) => VoiceTextTab.transcript),
        ],
        afterSettle: (tester) async {
          // A phone arrives on the call, so the chat is opened the way a person does.
          if (find.byKey(voiceTextTabsKey).evaluate().isEmpty) {
            await tester.tap(find.bySemanticsLabel('Toggle text chat'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          }
          expect(find.byKey(voiceTextTabsKey), findsOneWidget);
          for (final seq in [1, 2, 3, 4]) {
            expect(find.byKey(transcriptLineKey(seq)), findsOneWidget);
          }
        },
      );
    });
  }
}
