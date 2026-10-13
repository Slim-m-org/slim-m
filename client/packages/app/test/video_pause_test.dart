// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pausing incoming video when the window is out of sight: which lifecycle
/// states pause, that picture-in-picture and the setting are honoured, and
/// that the pause reaches the call as an empty video interest and lifts back.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/video_pause.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

FakeSession? _lastSession;

class _Call extends VoiceController {
  _Call(super.ref, List<VoiceParticipant> who, FakeSession session)
    : super(session: session) {
    state = VoiceState(
      channelId: 'c-main',
      state: VoiceSessionState.connected,
      participants: who,
    );
  }
}

Future<({ProviderContainer container, FakeSession session})> _rig({
  bool? pauseSetting = true,
  bool desktop = true,
  List<VoiceParticipant> who = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'slimm.voice.pause_video_when_unfocused': ?pauseSetting,
  });
  final session = FakeSession();
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      voiceControllerProvider.overrideWith((ref) => _Call(ref, who, session)),
      pauseOnUnfocusedAppliesProvider.overrideWithValue(desktop),
    ],
  );
  addTearDown(container.dispose);
  container.read(voiceSettingsControllerProvider);
  await container.read(preferencesProvider.future);
  await Future<void>.delayed(Duration.zero);
  _lastSession = session;
  return (container: container, session: session);
}

Future<void> _go(AppLifecycleState state) async {
  TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('shouldPauseLocalPreview', () {
    bool pauses(AppLifecycleState s, {bool setting = true, bool pip = false}) =>
        shouldPauseLocalPreview(
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

  group('only the local preview pauses', () {
    setUp(TestWidgetsFlutterBinding.ensureInitialized);
    tearDown(() => _go(AppLifecycleState.resumed));

    const remote = VoiceParticipant(
      identity: 'u-ada',
      name: 'Ada',
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: true,
    );
    const local = VoiceParticipant(
      identity: 'u-me',
      name: 'Me',
      isSpeaking: false,
      isMuted: false,
      isLocal: true,
      isScreenSharing: false,
      isCameraOn: true,
    );

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      bool? setting = true,
    }) async {
      final r = (await tester.runAsync(
        () => _rig(pauseSetting: setting, who: [remote, local]),
      ))!;
      final controller = r.container.read(voiceControllerProvider.notifier);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: r.container,
          child: Column(
            children: [
              controller.screenShareViewFor('u-ada'),
              controller.cameraViewFor('u-ada'),
              controller.cameraViewFor('u-me'),
            ],
          ),
        ),
      );
      return r.container;
    }

    final remoteShare = find.byKey(const Key('fake-share-view-u-ada'));
    final remoteCamera = find.byKey(const Key('fake-camera-view-u-ada'));
    final localCamera = find.byKey(const Key('fake-camera-view-u-me'));

    testWidgets(
      'an unfocused window keeps remote video and pauses the preview',
      (tester) async {
        final c = await pump(tester);
        expect(localCamera, findsOneWidget);
        c
            .read(appLifecycleProvider.notifier)
            .didChangeAppLifecycleState(AppLifecycleState.inactive);
        await tester.pump();
        expect(remoteShare, findsOneWidget);
        expect(remoteCamera, findsOneWidget);
        expect(localCamera, findsNothing);
      },
    );

    testWidgets('a minimised window still keeps remote video', (tester) async {
      final c = await pump(tester);
      c
          .read(appLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(remoteShare, findsOneWidget);
      expect(localCamera, findsNothing);
    });

    testWidgets('the preview comes back with focus', (tester) async {
      final c = await pump(tester);
      final life = c.read(appLifecycleProvider.notifier);
      life.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      life.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(localCamera, findsOneWidget);
    });

    testWidgets('the setting off keeps the preview while unfocused', (
      tester,
    ) async {
      final c = await pump(tester, setting: false);
      c
          .read(appLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      expect(localCamera, findsOneWidget);
      expect(remoteShare, findsOneWidget);
    });

    testWidgets('no lifecycle state sends an empty video interest', (
      tester,
    ) async {
      final c = await pump(tester);
      for (final s in AppLifecycleState.values) {
        c.read(appLifecycleProvider.notifier).didChangeAppLifecycleState(s);
        await tester.pump();
      }
      expect(_lastSession!.videoInterests, isEmpty);
    });
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
