// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Call surfaces that had no render: the marks list, the note sheet and the
/// captions strip before anything is said. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/call_audio.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_marks_list.dart';
import 'package:slimm_app/src/features/voice/widgets/call_captions_strip.dart';
import 'package:slimm_app/src/features/voice/widgets/call_note_sheet.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'support/fake_sync.dart';
import 'ui_snapshot_support.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

class _Audio extends CallAudioController {
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
          included: ['me'],
          pending: [],
          expiresAtMs: 4102444800000,
          full: false,
          always: true,
          transcriptId: 't1',
        ),
      ),
    );
  }
}

class _NoLines extends CallTranscriptController {
  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    return const CallTranscriptModel(loaded: true, ongoing: true);
  }
}

class _CaptionsOn extends VoiceSettingsController {
  _CaptionsOn(super.ref);

  @override
  set state(VoiceSettingsState value) =>
      super.state = value.copyWith(showCaptions: true);
}

Map<String, Object?> _mark(String id, String author, int at, {String? note}) =>
    {
      'id': id,
      'transcript_id': 't1',
      'author_id': author,
      'at': at,
      'line_seq': 1,
      'kind': note == null ? 'mark' : 'note',
      'text': note,
      'source': 'manual',
    };

final _marks = [
  _mark('a', 'me', 125000),
  _mark('b', 'kiki', 410000, note: 'Ship the retention change before Friday.'),
  _mark('c', 'me', 903000, note: 'Ask Bob about the lint rule.'),
];

Future<void> _show(
  WidgetTester tester,
  String name,
  Size size,
  Widget child, {
  bool sheet = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      voiceFlagsProvider.overrideWithValue(
        const VoiceFlags(channelId: 'voice-1'),
      ),
      callAudioProvider.overrideWith(_Audio.new),
      channelPermissionsProvider.overrideWith(
        (ref, id) async => Perm.viewChannel | Perm.viewTranscripts,
      ),
      myChannelPermissionsProvider.overrideWith(
        (ref, id) => Perm.viewChannel | Perm.viewTranscripts,
      ),
      userProfileProvider.overrideWith((ref, id) async => null),
      callTranscriptProvider.overrideWith(_NoLines.new),
      voiceSettingsControllerProvider.overrideWith(_CaptionsOn.new),
      apiProvider.overrideWith((ref) {
        final client = testApi(
          (request) async => http.Response(
            jsonEncode({'marks': _marks}),
            200,
            headers: {'content-type': 'application/json'},
          ),
          session: api.SessionStore(tokens: _tokens),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  Widget build(String theme) => UncontrolledProviderScope(
    container: container,
    child: RepaintBoundary(
      key: snapshotBoundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: snapshotThemeData(theme),
        home: Scaffold(
          body: sheet
              ? Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () => showCallNoteSheet(context),
                      child: const Text('open'),
                    ),
                  ),
                )
              : Align(alignment: Alignment.bottomCenter, child: child),
        ),
      ),
    ),
  );
  await tester.pumpWidget(build('dark'));
  await tester.pump();
  await tester.pump();
  if (sheet) {
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  await checkDarkThenLight(tester, build, (theme) async {
    await tester.pump(const Duration(milliseconds: 400));
    await writeSnapshot(tester, '$name-$theme');
    expect(tester.takeException(), isNull);
  });
}

void main() {
  setUpAll(loadRealFonts);

  for (final (label, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1100, 700)),
  ]) {
    testWidgets('marks list at $label', (tester) async {
      await _show(
        tester,
        'call-marks-list-$label',
        size,
        const Padding(
          padding: EdgeInsets.all(AppSpacing.s16),
          child: CallMarksList(channelId: 'voice-1', transcriptId: 't1'),
        ),
      );
    });
    testWidgets('note sheet at $label', (tester) async {
      await _show(
        tester,
        'call-note-sheet-$label',
        size,
        const SizedBox.shrink(),
        sheet: true,
      );
    });
    testWidgets('captions strip with nothing said at $label', (tester) async {
      await _show(
        tester,
        'call-captions-empty-$label',
        size,
        const Padding(
          padding: EdgeInsets.all(AppSpacing.s16),
          child: CallCaptionsStrip(channelId: 'voice-1'),
        ),
      );
    });
  }
}
