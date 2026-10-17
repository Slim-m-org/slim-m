// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Android picture-in-picture: when the call may float, what fills the window,
/// that the routed app survives it, and that the video stays subscribed.
///
/// The channel is built with `isAndroid: true` because `isAndroidHost` is false
/// in every `flutter test` run, so the mobile branch would otherwise never run.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/picture_in_picture.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/picture_in_picture_gate.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _channelName = 'top.npcserver.slimm/picture_in_picture';

class _FixedVoiceController extends VoiceController {
  _FixedVoiceController(super.ref, VoiceState fixed, FakeSession session)
    : super(session: session) {
    state = fixed;
  }

  void set(VoiceState next) => state = next;
}

const _share = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);
const _quiet = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

VoiceState _call(List<VoiceParticipant> who) => VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  participants: who,
);

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => taps++),
    child: Center(child: Text('taps $taps', key: const Key('routed'))),
  );
}

class _Rig {
  _Rig(this.tester, this.container, this.session, this.sent);

  final WidgetTester tester;
  final ProviderContainer container;
  final FakeSession session;
  final List<MethodCall> sent;

  _FixedVoiceController get voice =>
      container.read(voiceControllerProvider.notifier) as _FixedVoiceController;

  Future<void> native(bool inPip) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('modeChanged', inPip),
      ),
      (_) {},
    );
    await tester.pump();
  }

  List<bool> get eligibility => [
    for (final c in sent)
      if (c.method == 'setEligible') c.arguments as bool,
  ];
}

Future<_Rig> _pump(WidgetTester tester, VoiceState voice) async {
  final sent = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel(_channelName),
    (call) async {
      sent.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_channelName),
      null,
    ),
  );
  final session = FakeSession();
  final container = ProviderContainer(
    overrides: [
      voiceControllerProvider.overrideWith(
        (ref) => _FixedVoiceController(ref, voice, session),
      ),
      pictureInPictureChannelProvider.overrideWith((ref) {
        final channel = PictureInPictureChannel(isAndroid: true);
        ref.onDispose(channel.dispose);
        return channel;
      }),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: PictureInPictureGate(child: Scaffold(body: _Counter())),
      ),
    ),
  );
  await tester.pump();
  return _Rig(tester, container, session, sent);
}

void main() {
  final feed = find.byKey(pictureInPictureFeedKey);

  group('eligibility', () {
    testWidgets('a remote share makes the call eligible', (tester) async {
      final rig = await _pump(tester, _call([_share]));
      expect(rig.eligibility, [true]);
    });

    testWidgets('an audio-only call never floats', (tester) async {
      final rig = await _pump(tester, _call([_quiet]));
      expect(rig.eligibility, [false]);
    });

    testWidgets('the call ending withdraws eligibility', (tester) async {
      final rig = await _pump(tester, _call([_share]));
      rig.voice.set(const VoiceState());
      await tester.pump();
      expect(rig.eligibility, [true, false]);
    });

    testWidgets('the share stopping withdraws eligibility', (tester) async {
      final rig = await _pump(tester, _call([_share]));
      rig.voice.set(_call([_quiet]));
      await tester.pump();
      expect(rig.eligibility, [true, false]);
    });
  });

  group('the floating window', () {
    testWidgets('the feed fills the window and the app is hidden', (
      tester,
    ) async {
      final rig = await _pump(tester, _call([_share]));
      expect(feed, findsNothing);

      await rig.native(true);

      expect(tester.getRect(feed), const Rect.fromLTWH(0, 0, 390, 844));
      expect(
        find.descendant(
          of: feed,
          matching: find.byKey(const Key('fake-share-view-u-ada')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('routed')), findsNothing);
    });

    testWidgets('leaving it restores the same screen state', (tester) async {
      final rig = await _pump(tester, _call([_share]));
      await tester.tap(find.byKey(const Key('routed')));
      await tester.pump();

      await rig.native(true);
      await rig.native(false);

      expect(feed, findsNothing);
      expect(find.text('taps 1'), findsOneWidget);
    });

    testWidgets('a camera feed floats when there is no share', (tester) async {
      const camera = VoiceParticipant(
        identity: 'u-bo',
        name: 'Bo',
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: false,
        isCameraOn: true,
      );
      final rig = await _pump(tester, _call([camera]));
      await rig.native(true);
      expect(
        find.descendant(
          of: feed,
          matching: find.byKey(const Key('fake-camera-view-u-bo')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the call ending while floating puts the app back', (
      tester,
    ) async {
      final rig = await _pump(tester, _call([_share]));
      await rig.native(true);

      rig.voice.set(const VoiceState());
      await tester.pump();

      expect(feed, findsNothing);
      expect(find.byKey(const Key('routed')), findsOneWidget);
      expect(rig.session.videoInterests.last, isNull);
    });
  });

  group('the video stays subscribed', () {
    testWidgets('entering holds every track and leaving restores the canvas', (
      tester,
    ) async {
      final rig = await _pump(tester, _call([_share]));
      final relay = rig.container.read(videoInterestRelayProvider);
      relay.declare({'screen:u-other'});
      expect(rig.session.videoInterests, [
        {'screen:u-other'},
      ]);

      await rig.native(true);
      expect(rig.session.videoInterests.last, isNull);

      relay.declare({'screen:u-moved'});
      expect(rig.session.videoInterests.last, isNull);

      await rig.native(false);
      expect(rig.session.videoInterests.last, {'screen:u-moved'});
    });
  });

  group('VideoInterestRelay', () {
    test('holding twice applies once and releasing is idempotent', () {
      final applied = <Set<String>?>[];
      final relay = VideoInterestRelay(applied.add);
      relay.declare({'a'});
      relay
        ..hold(true)
        ..hold(true)
        ..hold(false)
        ..hold(false);
      expect(applied, [
        {'a'},
        null,
        {'a'},
      ]);
    });
  });
}
