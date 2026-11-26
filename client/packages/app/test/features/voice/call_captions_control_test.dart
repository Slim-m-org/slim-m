// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one Captions control (decision 0113): what each transcription mode
/// shows and does, the consent ask staying in place, and the passive banner
/// staying visible while captions are off.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/call_audio.dart';
import 'package:slimm_app/src/features/voice/providers/call_captions.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_audio_banner.dart';
import 'package:slimm_app/src/features/voice/widgets/call_captions_strip.dart';
import 'package:slimm_app/src/features/voice/widgets/captions_menu.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

const _channel = 'voice-1';

api.CallAudioState _session({
  bool on = true,
  bool always = false,
  String? transcriptId = 't1',
  String moduleId = api.CallAudioState.serverConsumerId,
}) => api.CallAudioState(
  moduleId: moduleId,
  moduleName: 'Call transcript',
  purpose: 'Writes down what is said.',
  keeps: 'Each line.',
  isOn: on,
  askedBy: always ? '' : 'me',
  included: const ['me'],
  pending: on ? const [] : const ['ada', 'bob'],
  expiresAtMs: 4102444800000,
  full: false,
  always: always,
  transcriptId: on ? transcriptId : null,
);

api.CallAudioStatus _status({
  api.CallAudioState? session,
  bool transcribable = false,
}) => api.CallAudioStatus(session: session, transcribable: transcribable);

class _Audio extends CallAudioController {
  _Audio(this._initial, {this.refuse});

  final api.CallAudioStatus _initial;
  final String? refuse;
  int asked = 0;

  @override
  CallAudioModel build(String arg) {
    channelId = arg;
    return CallAudioModel(status: _initial);
  }

  @override
  Future<void> requestTranscript() async {
    asked++;
    state = refuse != null
        ? state.copyWith(error: refuse)
        : state.copyWith(
            status: _status(session: _session(on: false), transcribable: true),
          );
  }

  void become(api.CallAudioStatus status, {String? ended}) =>
      state = state.copyWith(
        status: status,
        ended: ended,
        clearEnded: status.session != null,
      );
}

class _Lines extends CallTranscriptController {
  @override
  CallTranscriptModel build(String arg) {
    transcriptId = arg;
    return const CallTranscriptModel(loaded: true, ongoing: true);
  }
}

class _CaptionsDefaultOn extends VoiceSettingsController {
  _CaptionsDefaultOn(super.ref);

  @override
  set state(VoiceSettingsState value) =>
      super.state = value.copyWith(showCaptions: true);
}

class _Rig {
  _Rig(this.audio, this.container);

  final _Audio audio;
  final ProviderContainer container;
}

Future<_Rig> _pump(
  WidgetTester tester,
  api.CallAudioStatus status, {
  bool defaultOn = false,
  String? refuse,
}) async {
  final audio = _Audio(status, refuse: refuse);
  final container = ProviderContainer(
    overrides: [
      callAudioProvider.overrideWith(() => audio),
      channelPermissionsProvider.overrideWith(
        (ref, id) async => Perm.viewChannel | Perm.viewTranscripts,
      ),
      callTranscriptProvider.overrideWith(_Lines.new),
      userProfileProvider.overrideWith((ref, id) async => null),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 4102444800000,
          ),
        ),
      ),
      if (defaultOn)
        voiceSettingsControllerProvider.overrideWith(_CaptionsDefaultOn.new),
    ],
  );
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
                if (ref.watch(captionsControlProvider(_channel)) !=
                    CaptionsControl.hidden)
                  CaptionsDockButton(menuContext: context, channelId: _channel),
                const CallCaptionsStrip(channelId: _channel),
                const CallAudioBanner(channelId: _channel),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Rig(audio, container);
}

Future<void> _openMenu(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _flip(WidgetTester tester) async {
  await tester.tap(find.byKey(captionsSwitchKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _confirmAsk(WidgetTester tester) async {
  expect(find.text('Transcribe this call?'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('call-audio-ask-transcript')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

bool _switchOn(WidgetTester tester) =>
    tester.widget<AppMenuSwitchRow>(find.byKey(captionsSwitchKey)).value;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  testWidgets('off: the control is not shown', (tester) async {
    await _pump(tester, _status());
    expect(find.byTooltip('Captions'), findsNothing);
  });

  testWidgets('a module hearing the call does not offer captions', (
    tester,
  ) async {
    await _pump(
      tester,
      _status(
        session: _session(moduleId: 'notes', transcriptId: null),
        transcribable: true,
      ),
    );
    expect(find.byTooltip('Captions'), findsNothing);
  });

  group('always', () {
    final running = _status(session: _session(always: true));

    testWidgets('captions on only reveals the strip, off until asked', (
      tester,
    ) async {
      await _pump(tester, running);
      expect(find.byKey(callCaptionsKey), findsNothing);
      await _openMenu(tester, 'Captions');
      expect(_switchOn(tester), isFalse);
      await _flip(tester);
      expect(find.byKey(callCaptionsKey), findsOneWidget);
    });

    testWidgets('asks nobody and offers Mark and View transcript', (
      tester,
    ) async {
      final rig = await _pump(tester, running);
      await _openMenu(tester, 'Captions');
      expect(find.byKey(markButtonKey), findsOneWidget);
      expect(find.byKey(viewTranscriptKey), findsOneWidget);
      await _flip(tester);
      expect(rig.audio.asked, 0);
      expect(find.text('Transcribe this call?'), findsNothing);
    });

    testWidgets('the per-device default turns captions on by itself', (
      tester,
    ) async {
      await _pump(tester, running, defaultOn: true);
      expect(find.byKey(callCaptionsKey), findsOneWidget);
      await _openMenu(tester, 'Captions');
      expect(_switchOn(tester), isTrue);
    });

    testWidgets('no passive banner to answer, so nothing is hidden by it', (
      tester,
    ) async {
      await _pump(tester, running);
      expect(find.byKey(CallAudioBanner.stopKey), findsNothing);
      expect(find.byKey(callCaptionsKey), findsNothing);
    });
  });

  group('on_request', () {
    final startable = _status(transcribable: true);

    testWidgets('the menu holds only the switch until a transcript runs', (
      tester,
    ) async {
      await _pump(tester, startable);
      await _openMenu(tester, 'Captions');
      expect(_switchOn(tester), isFalse);
      expect(find.byKey(markButtonKey), findsNothing);
      expect(find.byKey(viewTranscriptKey), findsNothing);
    });

    testWidgets('the device default never asks anyone by itself', (
      tester,
    ) async {
      final rig = await _pump(tester, startable, defaultOn: true);
      await _openMenu(tester, 'Captions');
      expect(_switchOn(tester), isFalse);
      expect(rig.audio.asked, 0);
    });

    testWidgets('turning captions on asks everyone, after the sheet', (
      tester,
    ) async {
      final rig = await _pump(tester, startable);
      await _openMenu(tester, 'Captions');
      await _flip(tester);
      expect(rig.audio.asked, 0, reason: 'the sheet comes first');
      await _confirmAsk(tester);
      expect(rig.audio.asked, 1);
    });

    testWidgets('cancelling the sheet asks nobody and leaves captions off', (
      tester,
    ) async {
      final rig = await _pump(tester, startable);
      await _openMenu(tester, 'Captions');
      await _flip(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.audio.asked, 0);
      expect(rig.container.read(captionsOnProvider(_channel)), isFalse);
    });

    testWidgets('while pending the control says so, and the banner stays', (
      tester,
    ) async {
      await _pump(tester, startable);
      await _openMenu(tester, 'Captions');
      await _flip(tester);
      await _confirmAsk(tester);
      expect(find.byTooltip('Captions, waiting for everyone'), findsOneWidget);
      await _openMenu(tester, 'Captions, waiting for everyone');
      for (final text in ['Waiting for everyone', '1 of 3']) {
        expect(
          find.descendant(
            of: find.byKey(captionsPendingKey),
            matching: find.text(text),
          ),
          findsOneWidget,
        );
      }
      expect(find.byKey(captionsSwitchKey), findsNothing);
      expect(find.byKey(CallAudioBanner.stopKey), findsOneWidget);
    });

    testWidgets('a decline turns captions off and the banner explains', (
      tester,
    ) async {
      final rig = await _pump(tester, startable);
      await _openMenu(tester, 'Captions');
      await _flip(tester);
      await _confirmAsk(tester);
      rig.audio.become(_status(transcribable: true), ended: 'declined');
      await tester.pump();
      expect(rig.container.read(captionsOnProvider(_channel)), isFalse);
      expect(find.byKey(callCaptionsKey), findsNothing);
      expect(
        find.text('Not everyone agreed, so nothing is listening.'),
        findsOneWidget,
      );
      await _openMenu(tester, 'Captions');
      expect(_switchOn(tester), isFalse);
    });

    testWidgets('once everyone agrees the strip shows without another tap', (
      tester,
    ) async {
      final rig = await _pump(tester, startable);
      await _openMenu(tester, 'Captions');
      await _flip(tester);
      await _confirmAsk(tester);
      expect(find.byKey(callCaptionsKey), findsNothing);
      rig.audio.become(_status(session: _session(), transcribable: true));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(callCaptionsKey), findsOneWidget);
    });

    testWidgets(
      'a running transcript the viewer did not ask to see stays off',
      (tester) async {
        final rig = await _pump(tester, startable);
        rig.audio.become(_status(session: _session(), transcribable: true));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(callCaptionsKey), findsNothing);
        expect(find.byKey(CallAudioBanner.stopKey), findsOneWidget);
        await _openMenu(tester, 'Captions');
        expect(find.byKey(markButtonKey), findsOneWidget);
      },
    );

    testWidgets('a refused ask leaves captions off', (tester) async {
      final rig = await _pump(tester, startable, refuse: 'Not allowed');
      await _openMenu(tester, 'Captions');
      await _flip(tester);
      await _confirmAsk(tester);
      expect(rig.container.read(captionsOnProvider(_channel)), isFalse);
    });
  });

  group('the Chat | Transcript pane switch', () {
    testWidgets(
      'is offered only once captions are on or the transcript is viewed',
      (tester) async {
        final rig = await _pump(
          tester,
          _status(session: _session(always: true)),
        );
        bool offered() =>
            rig.container.read(transcriptPaneOfferedProvider(_channel));
        expect(offered(), isFalse);

        await _openMenu(tester, 'Captions');
        await _flip(tester);
        expect(offered(), isTrue, reason: 'captions on');
        await _flip(tester);
        expect(offered(), isFalse, reason: 'captions off again');

        await tester.tap(find.byKey(viewTranscriptKey));
        await tester.pump();
        expect(offered(), isTrue, reason: 'View transcript');
      },
    );

    testWidgets('is withdrawn once the transcript ends', (tester) async {
      final rig = await _pump(tester, _status(session: _session(always: true)));
      await _openMenu(tester, 'Captions');
      await _flip(tester);
      rig.audio.become(_status());
      await tester.pump();
      expect(
        rig.container.read(transcriptPaneOfferedProvider(_channel)),
        isFalse,
      );
      expect(
        rig.container.read(callCaptionsProvider(_channel)).captions,
        isNull,
      );
    });
  });
}
