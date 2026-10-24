// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pausing incoming video when the window is out of sight: which lifecycle
/// states pause, that picture-in-picture and the setting are honoured, and
/// that the pause reaches the call as an empty video interest and lifts back,
/// and that a call with no mounted video wants none.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/features/voice/providers/video_interest_relay.dart';
import 'package:slimm_app/src/features/voice/providers/video_pause.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_design_system/design_system.dart';
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
    bool pauses(
      AppLifecycleState s, {
      bool setting = true,
      bool desktop = true,
      bool pip = false,
    }) => shouldPauseLocalPreview(
      lifecycle: s,
      pauseWhenMinimised: setting,
      desktop: desktop,
      pictureInPicture: pip,
    );

    const away = [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ];

    test('a focused or merely unfocused window never pauses', () {
      for (final setting in [true, false]) {
        for (final desktop in [true, false]) {
          for (final s in [
            AppLifecycleState.resumed,
            AppLifecycleState.inactive,
          ]) {
            expect(
              pauses(s, setting: setting, desktop: desktop),
              isFalse,
              reason: '$s setting=$setting desktop=$desktop',
            );
          }
        }
      }
    });

    test('a hidden desktop window pauses only when the setting is on', () {
      for (final s in away) {
        expect(pauses(s), isTrue, reason: '$s');
        expect(pauses(s, setting: false), isFalse, reason: '$s off');
      }
    });

    test('a backgrounded phone pauses whatever the setting says', () {
      for (final s in away) {
        expect(pauses(s, desktop: false, setting: false), isTrue, reason: '$s');
      }
    });

    test('picture-in-picture is never paused', () {
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
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Column(
              children: [
                for (final tile in [
                  controller.screenShareViewFor('u-ada'),
                  controller.cameraViewFor('u-ada'),
                  controller.cameraViewFor('u-me'),
                ])
                  SizedBox(width: 320, height: 160, child: tile),
              ],
            ),
          ),
        ),
      );
      return r.container;
    }

    final remoteShare = find.byKey(const Key('fake-share-view-u-ada'));
    final remoteCamera = find.byKey(const Key('fake-camera-view-u-ada'));
    final localCamera = find.byKey(const Key('fake-camera-view-u-me'));

    testWidgets('an unfocused window keeps remote video and the preview', (
      tester,
    ) async {
      final c = await pump(tester);
      c
          .read(appLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      expect(remoteShare, findsOneWidget);
      expect(remoteCamera, findsOneWidget);
      expect(localCamera, findsOneWidget);
    });

    testWidgets('a minimised window still keeps remote video tiles', (
      tester,
    ) async {
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
      life.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      life.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(localCamera, findsOneWidget);
    });

    testWidgets('the setting off keeps the preview while minimised', (
      tester,
    ) async {
      final c = await pump(tester, setting: false);
      c
          .read(appLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(localCamera, findsOneWidget);
      expect(remoteShare, findsOneWidget);
    });

    testWidgets(
      'a window nobody can see receives no video and resumes on return',
      (tester) async {
        final c = await pump(tester);
        c.read(videoInterestHostProvider);
        await tester.pump();
        const shown = {'screen:u-ada', 'camera:u-ada', 'camera:u-me'};
        c.read(videoInterestRelayProvider).refresh();
        expect(_lastSession!.videoInterests.last, shown);

        for (final s in [
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.detached,
        ]) {
          c.read(appLifecycleProvider.notifier).didChangeAppLifecycleState(s);
          await tester.pump();
          expect(_lastSession!.videoInterests.last, isEmpty, reason: '$s');
          c
              .read(appLifecycleProvider.notifier)
              .didChangeAppLifecycleState(AppLifecycleState.resumed);
          await tester.pump();
          expect(_lastSession!.videoInterests.last, shown, reason: '$s back');
        }
      },
    );

    testWidgets('an unfocused window keeps its video interest', (tester) async {
      final c = await pump(tester);
      c.read(videoInterestHostProvider);
      await tester.pump();
      c.read(videoInterestRelayProvider).refresh();
      final shown = _lastSession!.videoInterests.last;
      expect(shown, isNotEmpty);
      c
          .read(appLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      expect(c.read(remoteVideoSeenProvider), isTrue);
      expect(_lastSession!.videoInterests.last, shown);
    });

    testWidgets('minimising keeps receiving video when the setting is off', (
      tester,
    ) async {
      final c = await pump(tester, setting: false);
      c.read(videoInterestHostProvider);
      await tester.pump();
      c
          .read(appLifecycleProvider.notifier)
          .didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(c.read(remoteVideoSeenProvider), isTrue);
    });

    test(
      'a phone still pauses when backgrounded, not on a shade pull',
      () async {
        SharedPreferences.setMockInitialValues({});
        final c = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWith(
              (ref) => SharedPreferences.getInstance(),
            ),
            pauseOnUnfocusedAppliesProvider.overrideWithValue(false),
          ],
        );
        addTearDown(c.dispose);
        final life = c.read(appLifecycleProvider.notifier);
        life.didChangeAppLifecycleState(AppLifecycleState.inactive);
        expect(c.read(remoteVideoSeenProvider), isTrue);
        life.didChangeAppLifecycleState(AppLifecycleState.paused);
        expect(c.read(remoteVideoSeenProvider), isFalse);
        await c.read(preferencesProvider.future);
        await Future<void>.delayed(Duration.zero);
      },
    );

    testWidgets('a connected call with no video mounted wants none', (
      tester,
    ) async {
      final r = (await tester.runAsync(() => _rig(who: [remote])))!;
      r.container.read(videoInterestHostProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: r.container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      r.container.read(videoInterestRelayProvider).refresh();
      expect(r.session.videoInterests.last, isEmpty);
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
