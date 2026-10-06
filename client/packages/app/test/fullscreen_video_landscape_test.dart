// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone may rotate only while a call's video is full screen (decision
/// 0058): the view asks for landscape, gives it back on every way out, and
/// the routed app below it keeps its portrait size while the video fills the
/// real landscape window.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/phone_landscape.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/screens/voice_screen.dart';
import 'package:slimm_app/src/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Me',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

const _aliceOnCamera = VoiceParticipant(
  identity: 'user-2',
  name: 'Alice',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _portrait = Size(430, 932);
const _landscape = Size(932, 430);

class _FakeOrientation extends OrientationChannel {
  _FakeOrientation({required this.lockedPhone})
    : super(channel: const MethodChannel('test/orientation'));

  final bool lockedPhone;
  final calls = <bool>[];

  @override
  Future<bool> allowLandscape(bool allowed) async {
    calls.add(allowed);
    return lockedPhone;
  }
}

class _Fixture {
  _Fixture(this.harness, this.session, this.orientation);

  final VoiceHarness harness;
  final FakeSession session;
  final _FakeOrientation orientation;

  Future<void> leave() =>
      harness.container.read(voiceControllerProvider.notifier).leave();
}

Future<_Fixture> _openFullscreen(
  WidgetTester tester, {
  bool lockedPhone = true,
}) async {
  tester.view.physicalSize = _portrait;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final harness = VoiceHarness();
  final session = FakeSession();
  final orientation = _FakeOrientation(lockedPhone: lockedPhone);
  final controller = harness.controllerWith(
    session,
    voiceApi(),
    extraOverrides: [
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
      orientationChannelProvider.overrideWithValue(orientation),
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        // What appChromeBuilder does above the navigator.
        builder: (context, child) => Consumer(
          builder: (context, ref, _) {
            // Subscribes to the window size the way appChromeBuilder's ambient MediaQuery does.
            MediaQuery.sizeOf(context);
            return MediaQuery(
              data: keepPortraitShell(
                MediaQueryData.fromView(View.of(context)),
                lockedPhone: ref.watch(portraitLockedPhoneProvider),
              ),
              child: child!,
            );
          },
        ),
        home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
      ),
    ),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  await tester.pump();
  session.emitParticipants(const [_me, _aliceOnCamera]);
  await tester.pumpAndSettle();

  await tester.tap(find.byType(ExpandVideoButton));
  await tester.pumpAndSettle();
  expect(find.byType(FullscreenVideoView), findsOneWidget);
  return _Fixture(harness, session, orientation);
}

Finder get _closeButton => find.byWidgetPredicate(
  (w) => w is AppIconButton && w.semanticLabel == 'Exit full screen',
);

Finder get _fullscreenFeed => find.descendant(
  of: find.byType(FullscreenVideoView),
  matching: find.byKey(const Key('fake-camera-view-user-2')),
);

void main() {
  testWidgets('opening asks to rotate and the close button gives it back', (
    tester,
  ) async {
    final fixture = await _openFullscreen(tester);
    addTearDown(fixture.harness.dispose);
    expect(fixture.orientation.calls, [true]);

    await tester.tap(_closeButton);
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenVideoView), findsNothing);
    expect(fixture.orientation.calls, [true, false]);
    await fixture.leave();
  });

  testWidgets('Escape gives the lock back too', (tester) async {
    final fixture = await _openFullscreen(tester);
    addTearDown(fixture.harness.dispose);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(fixture.orientation.calls.last, isFalse);
    await fixture.leave();
  });

  testWidgets('the feed ending closes the view and gives the lock back', (
    tester,
  ) async {
    final fixture = await _openFullscreen(tester);
    addTearDown(fixture.harness.dispose);

    fixture.session.emitParticipants(const [_me]);
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenVideoView), findsNothing);
    expect(fixture.orientation.calls.last, isFalse);
    await fixture.leave();
  });

  testWidgets(
    'rotated, the video fills the landscape window while the app below '
    'keeps its portrait size',
    (tester) async {
      final fixture = await _openFullscreen(tester);
      addTearDown(fixture.harness.dispose);

      tester.view.physicalSize = _landscape;
      await tester.pumpAndSettle();

      final shell = tester.element(
        find.byType(VoiceScreen, skipOffstage: false),
      );
      expect(MediaQuery.sizeOf(shell), _portrait);
      expect(tester.getSize(_fullscreenFeed).width, _landscape.width);
      await fixture.leave();
    },
  );

  testWidgets('in landscape a tap hides and shows the controls', (
    tester,
  ) async {
    final fixture = await _openFullscreen(tester);
    addTearDown(fixture.harness.dispose);
    tester.view.physicalSize = _landscape;
    await tester.pumpAndSettle();
    expect(_closeButton, findsOneWidget);

    await tester.tap(_fullscreenFeed);
    await tester.pumpAndSettle();
    expect(_closeButton, findsNothing);

    await tester.tap(_fullscreenFeed);
    await tester.pumpAndSettle();
    expect(_closeButton, findsOneWidget);
    await fixture.leave();
  });

  test(
    'keepPortraitShell leaves a free device and a portrait window alone',
    () {
      const wide = MediaQueryData(size: _landscape);
      expect(keepPortraitShell(wide, lockedPhone: false).size, _landscape);
      expect(keepPortraitShell(wide, lockedPhone: true).size, _portrait);
      const tall = MediaQueryData(size: _portrait);
      expect(keepPortraitShell(tall, lockedPhone: true).size, _portrait);
    },
  );
}
