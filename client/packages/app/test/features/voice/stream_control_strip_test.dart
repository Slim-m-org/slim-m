// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The control strip on a share's stage: when it shows, where it sits, that a
/// press on its buttons never counts as a double click on the video, and that
/// its quality pick writes the one global Watching quality setting.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/features/voice/widgets/share_stage_grid.dart';
import 'package:slimm_app/src/features/voice/widgets/stream_controls_reveal.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _stage = ValueKey('strip-test-stage');
const _fade = Duration(milliseconds: 300);

// A pointer leaving lands after a frame, the fade runs, and the switcher drops the strip a frame later.
Future<void> _fadeOut(WidgetTester tester, [Duration extra = _fade]) async {
  await tester.pump();
  await tester.pump(extra);
  await tester.pump(_fade);
  await tester.pump();
}

// A fixed run of frames long enough for a menu or fade to finish, without waiting on a ticker that may never stop.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

class _SoundSession extends FakeSession {
  @override
  bool hasScreenAudio(String identity) => true;
}

VoiceParticipant _sharer({bool isLocal = false}) => VoiceParticipant(
  identity: isLocal ? 'me' : 'u-ada',
  name: isLocal ? 'Me' : 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: isLocal,
  isScreenSharing: true,
);

class _Rig {
  _Rig(this.session, this.harness, this.expanded);
  final FakeSession session;
  final VoiceHarness harness;
  final List<int> expanded;
}

Future<_Rig> _pump(
  WidgetTester tester, {
  Size window = const Size(1200, 800),
  Size stage = const Size(640, 360),
  bool sound = true,
  bool isLocal = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final session = sound ? _SoundSession() : FakeSession();
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  final controller = harness.controllerWith(session, voiceApi());
  final expanded = <int>[];
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        builder: (context, child) =>
            Material(type: MaterialType.transparency, child: child),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              key: _stage,
              width: stage.width,
              height: stage.height,
              child: Builder(
                builder: (context) => ScreenShareStage(
                  sharerName: 'Ada',
                  isLocal: isLocal,
                  onExpand: () => expanded.add(expanded.length),
                  onStopWatching: () {},
                  stripVolume: sound && !isLocal
                      ? (hold) => shareStripVolume(
                          _sharer(isLocal: isLocal),
                          controller,
                          hold,
                        )
                      : null,
                  stripQuality: isLocal
                      ? null
                      : (hold) => shareStripQuality(
                          _sharer(isLocal: isLocal),
                          controller,
                          hold,
                        ),
                  child: const SizedBox(),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return _Rig(session, harness, expanded);
}

Future<TestGesture> _hover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(2, 2));
  addTearDown(mouse.removePointer);
  await tester.pump();
  await mouse.moveTo(tester.getCenter(find.byKey(_stage)));
  await _fadeOut(tester);
  return mouse;
}

bool _focusIsOn(IconData icon) =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<AppIconButton>()
        ?.icon ==
    icon;

final _expand = find.byIcon(AppIcons.expand);
final _more = find.byIcon(AppIcons.moreHorizontal);
final _chip = find.byIcon(AppIcons.requestLatency);

void main() {
  testWidgets('the strip waits for a pointer and leaves with it', (
    tester,
  ) async {
    await _pump(tester);
    expect(_expand, findsNothing);
    expect(_more, findsNothing);

    final mouse = await _hover(tester);
    expect(_expand, findsOneWidget);
    expect(_more, findsOneWidget);
    expect(_chip, findsOneWidget);

    await mouse.moveTo(const Offset(2, 2));
    await _fadeOut(tester);
    expect(_expand, findsNothing);
  });

  testWidgets('keyboard focus on the stage brings the strip up', (
    tester,
  ) async {
    await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await _fadeOut(tester);
    expect(_more, findsOneWidget);

    var tabs = 0;
    while (tabs++ < 10 && !_focusIsOn(AppIcons.moreHorizontal)) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(
      find.text('Stop watching'),
      findsOneWidget,
      reason: 'tab reached it',
    );
  });

  testWidgets('the strip sits inside the stage, along its top right edge', (
    tester,
  ) async {
    await _pump(tester);
    await _hover(tester);
    final stage = tester.getRect(find.byKey(_stage));
    final strip = tester.getRect(_more);
    expect(stage.contains(strip.topLeft), isTrue);
    expect(stage.contains(strip.bottomRight), isTrue);
    expect(strip.top - stage.top, lessThan(24), reason: 'along the top edge');
    expect(stage.right - strip.right, lessThan(24), reason: 'at the right');
    expect(tester.getRect(_expand).right, lessThanOrEqualTo(strip.left));
  });

  testWidgets('a touch brings the strip up for four seconds', (tester) async {
    await _pump(tester);
    await tester.tapAt(tester.getCenter(find.byKey(_stage)));
    await _fadeOut(tester);
    expect(_expand, findsOneWidget);

    await tester.pump(kStreamControlsTouchHold - const Duration(seconds: 1));
    expect(_expand, findsOneWidget, reason: 'still inside the hold');

    await _fadeOut(tester, const Duration(seconds: 1) + _fade);
    expect(_expand, findsNothing);
  });

  testWidgets('a double press on a strip button never enters full screen', (
    tester,
  ) async {
    final rig = await _pump(tester);
    await _hover(tester);

    await tester.tap(_more);
    await tester.tap(_more);
    await _fadeOut(tester);
    expect(rig.expanded, isEmpty);

    await tester.tap(_expand);
    await _fadeOut(tester);
    expect(rig.expanded, hasLength(1), reason: 'the button itself still acts');
  });

  testWidgets('a double click on the video itself still enters full screen', (
    tester,
  ) async {
    final rig = await _pump(tester);
    final centre = tester.getCenter(find.byKey(_stage)) + const Offset(0, 60);
    await tester.tapAt(centre);
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 50));
    expect(rig.expanded, hasLength(1));
  });

  testWidgets('the options button opens the tile menu beside itself', (
    tester,
  ) async {
    await _pump(tester);
    await _hover(tester);
    await tester.tap(_more);
    await _settle(tester);

    expect(find.text('Stop watching'), findsOneWidget);
    expect(find.text('Full screen'), findsOneWidget);
    final button = tester.getRect(_more);
    final menu = tester.getRect(find.text('Stop watching'));
    expect((menu.top - button.bottom).abs(), lessThan(48));
    expect(menu.left, greaterThan(button.left - 220));

    await tester.tap(_more);
    await _settle(tester);
    expect(find.text('Stop watching'), findsNothing);
  });

  testWidgets('an open menu keeps the strip up after the pointer leaves', (
    tester,
  ) async {
    await _pump(tester);
    final mouse = await _hover(tester);
    await mouse.moveTo(tester.getCenter(_more));
    await mouse.down(tester.getCenter(_more));
    await mouse.up();
    await _settle(tester);
    expect(find.text('Stop watching'), findsOneWidget);

    await mouse.moveTo(const Offset(2, 790));
    await _fadeOut(tester);
    expect(_more, findsOneWidget, reason: 'held by the open menu');

    await mouse.down(const Offset(2, 790));
    await mouse.up();
    await _settle(tester);
    await _fadeOut(tester);
    expect(find.text('Stop watching'), findsNothing);
    expect(_more, findsNothing, reason: 'the hold ends with the menu');
  });

  testWidgets('the quality chip opens a pick headed as global and writes it', (
    tester,
  ) async {
    final rig = await _pump(tester);
    await _hover(tester);
    await tester.tap(_chip);
    await _settle(tester);

    expect(find.text('WATCHING QUALITY (ALL STREAMS)'), findsOneWidget);
    for (final label in ['Max', 'Auto', 'Balanced', 'Data saver']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('Data saver'));
    await _settle(tester);
    expect(rig.session.lastReceiveVideoQuality, ReceiveVideoQuality.dataSaver);
    expect(find.text('Data saver'), findsNothing, reason: 'the pick closes');
  });

  testWidgets('quality is only sampled while the strip is up', (tester) async {
    final rig = await _pump(tester);
    expect(rig.session.callStats.running, isFalse);

    final mouse = await _hover(tester);
    expect(rig.session.callStats.running, isTrue);

    await mouse.moveTo(const Offset(2, 2));
    await _fadeOut(tester);
    expect(rig.session.callStats.running, isFalse);
  });

  testWidgets('your own share has no quality chip and no volume', (
    tester,
  ) async {
    await _pump(tester, isLocal: true);
    await _hover(tester);
    expect(_chip, findsNothing);
    expect(find.bySubtype<AppSlider>(), findsNothing);
    expect(_expand, findsOneWidget);
  });

  testWidgets('a wide strip carries the volume and a held drag keeps it up', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tapAt(tester.getCenter(find.byKey(_stage)));
    await _fadeOut(tester);
    expect(find.bySubtype<AppSlider>(), findsOneWidget);

    final drag = await tester.startGesture(
      tester.getCenter(find.bySubtype<AppSlider>()),
    );
    await drag.moveBy(const Offset(40, 0));
    await tester.pump(kStreamControlsTouchHold * 2);
    expect(_expand, findsOneWidget, reason: 'held while the slider is down');

    await drag.up();
    await tester.pump(kStreamControlsTouchHold - const Duration(seconds: 1));
    expect(_expand, findsOneWidget, reason: 'the hold restarts on release');
    await _fadeOut(tester, const Duration(seconds: 1) + _fade);
    expect(_expand, findsNothing);
  });

  testWidgets('a narrow stage keeps the volume in the menu alone', (
    tester,
  ) async {
    await _pump(tester, stage: const Size(300, 170));
    await _hover(tester);
    expect(find.bySubtype<AppSlider>(), findsNothing);
    expect(_more, findsOneWidget);
  });

  testWidgets('on a phone every strip control is a 44 point target', (
    tester,
  ) async {
    await _pump(
      tester,
      window: const Size(390, 844),
      stage: const Size(358, 201),
    );
    await tester.tapAt(tester.getCenter(find.byKey(_stage)));
    await _fadeOut(tester);

    final stage = tester.getRect(find.byKey(_stage));
    for (final icon in [AppIcons.expand, AppIcons.moreHorizontal]) {
      final button = find.ancestor(
        of: find.byIcon(icon),
        matching: find.bySubtype<AppIconButton>(),
      );
      final size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(AppSizes.rowTouch));
      expect(size.height, greaterThanOrEqualTo(AppSizes.rowTouch));
      expect(stage.contains(tester.getRect(button).bottomRight), isTrue);
    }
    expect(find.bySubtype<AppSlider>(), findsNothing);
  });
}
