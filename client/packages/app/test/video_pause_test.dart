// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pausing incoming video when the window is out of sight: which lifecycle
/// states pause, that picture-in-picture and the setting are honoured, and
/// that the pause reaches the call as an empty video interest and lifts back.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/picture_in_picture.dart';
import 'package:slimm_app/src/providers/video_pause.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

Future<({ProviderContainer container, FakeSession session})> _rig({
  bool pauseSetting = true,
  bool desktop = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'slimm.voice.pause_video_when_unfocused': pauseSetting,
  });
  final session = FakeSession();
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
      pauseOnUnfocusedAppliesProvider.overrideWithValue(desktop),
    ],
  );
  addTearDown(container.dispose);
  container.read(voiceSettingsControllerProvider);
  await container.read(preferencesProvider.future);
  await Future<void>.delayed(Duration.zero);
  container.read(videoPauseHostProvider);
  return (container: container, session: session);
}

Future<void> _go(AppLifecycleState state) async {
  TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('shouldPauseVideo', () {
    bool pauses(AppLifecycleState s, {bool setting = true, bool pip = false}) =>
        shouldPauseVideo(
          lifecycle: s,
          pauseWhenUnfocused: setting,
          pictureInPicture: pip,
        );

    test('a focused window never pauses', () async {
      expect(pauses(AppLifecycleState.resumed), isFalse);
    });

    test(
      'hidden, paused and detached pause whatever the setting says',
      () async {
        for (final s in [
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.detached,
        ]) {
          expect(pauses(s, setting: false), isTrue, reason: '$s');
        }
      },
    );

    test('an unfocused window pauses only when the setting is on', () async {
      expect(pauses(AppLifecycleState.inactive), isTrue);
      expect(pauses(AppLifecycleState.inactive, setting: false), isFalse);
    });

    test('picture-in-picture is never paused', () async {
      for (final s in AppLifecycleState.values) {
        expect(pauses(s, pip: true), isFalse, reason: '$s');
      }
    });
  });

  group('the pause reaches the call', () {
    setUp(TestWidgetsFlutterBinding.ensureInitialized);
    tearDown(() => _go(AppLifecycleState.resumed));

    test(
      'minimising declares no video and restoring re-declares the canvas',
      () async {
        final r = await _rig();
        r.container.read(videoInterestRelayProvider).declare({'camera:u-ada'});
        r.session.videoInterests.clear();

        await _go(AppLifecycleState.hidden);
        expect(r.session.videoInterests, [<String>{}]);

        await _go(AppLifecycleState.resumed);
        expect(r.session.videoInterests.last, {'camera:u-ada'});
      },
    );

    test('an unfocused desktop window pauses and focus lifts it', () async {
      final r = await _rig();
      r.session.videoInterests.clear();
      await _go(AppLifecycleState.inactive);
      expect(r.session.videoInterests.last, <String>{});
      await _go(AppLifecycleState.resumed);
      expect(r.session.videoInterests.last, isNull);
    });

    test('the setting off keeps an unfocused window playing', () async {
      final r = await _rig(pauseSetting: false);
      r.session.videoInterests.clear();
      await _go(AppLifecycleState.inactive);
      expect(r.session.videoInterests, isEmpty);
      await _go(AppLifecycleState.hidden);
      expect(r.session.videoInterests.last, <String>{});
    });

    test(
      'a phone ignores a mere loss of focus but pauses when backgrounded',
      () async {
        final r = await _rig(desktop: false);
        r.session.videoInterests.clear();
        await _go(AppLifecycleState.inactive);
        expect(r.session.videoInterests, isEmpty);
        await _go(AppLifecycleState.paused);
        expect(r.session.videoInterests.last, <String>{});
      },
    );

    test(
      'picture-in-picture keeps the video while the app is backgrounded',
      () async {
        final r = await _rig();
        r.container.read(inPictureInPictureProvider.notifier).state = true;
        r.session.videoInterests.clear();
        await _go(AppLifecycleState.paused);
        expect(r.session.videoInterests, isEmpty);
      },
    );
  });

  group('the cull path', () {
    test(
      'an empty interest unsubscribes video after the dwell and never audio',
      () {
        fakeAsync((async) {
          final calls = <String>[];
          late VideoSubscriptionCuller culler;
          List<VideoSubscriptionRef> tracks() => [
            for (final key in ['camera:u-ada', 'screen:u-ada', 'audio:u-ada'])
              (
                key: key,
                subscribed: true,
                subscribe: () async => calls.add('sub $key'),
                unsubscribe: () async => calls.add('unsub $key'),
              ),
          ];
          culler = VideoSubscriptionCuller(onDue: () => culler.apply(tracks()));
          culler.setInterest(<String>{});
          culler.apply(tracks());
          async.elapse(videoSubscriptionDwell + const Duration(seconds: 1));
          expect(calls, ['unsub camera:u-ada', 'unsub screen:u-ada']);

          calls.clear();
          culler.setInterest(null);
          culler.apply([
            for (final t in tracks())
              (
                key: t.key,
                subscribed: false,
                subscribe: t.subscribe,
                unsubscribe: t.unsubscribe,
              ),
          ]);
          expect(calls, ['sub camera:u-ada', 'sub screen:u-ada']);
          culler.dispose();
        });
      },
    );
  });
}
