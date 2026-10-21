// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0086 and the 2026-10-20 owner call: a locked phone turns to
/// landscape only while a canvas tile is full screen, and the canvas then lays
/// out from the real window. Mobile-only, so the orientation channel is faked:
/// `flutter test` on Linux never answers it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane_body.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/phone_landscape.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

const _portrait = Size(430, 932);
const _landscape = Size(932, 430);

class _FakeOrientation extends OrientationChannel {
  _FakeOrientation() : super(channel: const MethodChannel('test/orientation'));

  final calls = <bool>[];

  @override
  Future<bool> allowLandscape(bool allowed) async {
    calls.add(allowed);
    return true;
  }
}

class _Voice extends VoiceController {
  _Voice(super.ref) : super(session: FakeSession()) {
    state = const VoiceState(
      channelId: 'c1',
      state: VoiceSessionState.connected,
      participants: [
        VoiceParticipant(
          identity: 'user-ada',
          name: 'Ada',
          isSpeaking: false,
          isMuted: false,
          isLocal: false,
          isScreenSharing: true,
        ),
      ],
    );
  }
}

Size _paneSize(WidgetTester tester) =>
    MediaQuery.sizeOf(tester.element(find.byType(CanvasPaneBody)));

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _FakeOrientation orientation,
) async {
  tester.view.physicalSize = _portrait;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [
      voiceControllerProvider.overrideWith(_Voice.new),
      orientationChannelProvider.overrideWithValue(orientation),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  container.read(canvasOpenProvider.notifier).state = 'c1';
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        // What appChromeBuilder does above the navigator.
        builder: (context, child) => Consumer(
          builder: (context, ref, _) {
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
        home: const Scaffold(body: CanvasPane(channelId: 'c1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('focusing a tile unlocks landscape and the canvas reads the '
      'real window; ending the focus locks it again', (tester) async {
    final orientation = _FakeOrientation();
    final container = await _pump(tester, orientation);
    expect(orientation.calls, isEmpty, reason: 'nothing rotates until a tile');
    expect(_paneSize(tester), _portrait);

    await tester.longPress(find.byKey(const ValueKey('screen:user-ada')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full screen'));
    await tester.pumpAndSettle();

    expect(orientation.calls, [true]);
    expect(container.read(portraitLockedPhoneProvider), isTrue);

    tester.view.physicalSize = _landscape;
    await tester.pumpAndSettle();
    expect(
      _paneSize(tester),
      _landscape,
      reason:
          'the canvas lays out from the real window, not the portrait shell',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(orientation.calls, [true, false]);
    expect(
      _paneSize(tester),
      _portrait,
      reason: 'the shell keeps its portrait size once the tile is released',
    );
  });

  testWidgets('a canvas with no full screen tile never asks to rotate', (
    tester,
  ) async {
    final orientation = _FakeOrientation();
    await _pump(tester, orientation);

    tester.view.physicalSize = _landscape;
    await tester.pumpAndSettle();

    expect(orientation.calls, isEmpty);
    expect(
      _paneSize(tester),
      _landscape,
      reason: 'unlocked here, so nothing swaps',
    );
  });
}
