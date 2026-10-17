// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The whole collapsed call strip is the way back to the call.
///
/// Drives the real shell at phone width with a fixed call session. A press on
/// the avatar, the title, the timer or any bare patch of the bar returns to
/// the call; mute, deafen and leave keep their own action and never also
/// navigate. The old small back arrow is gone.
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_strip_press_area.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

class _CountingVoiceController extends VoiceController {
  _CountingVoiceController(super.ref, VoiceState fixed)
    : super(session: FakeSession()) {
    state = fixed;
  }

  final calls = <String>[];

  @override
  Future<void> toggleMicrophone() async => calls.add('mute');

  @override
  Future<void> toggleDeafen() async => calls.add('deafen');

  @override
  Future<void> leave() async => calls.add('leave');
}

const _elsewhere = '/channels/c-general';
const _callRoute = '/channels/c-main';

class _Rig {
  _Rig(this.router, this.controller, this.fixture);
  final GoRouter router;
  final _CountingVoiceController controller;
  final ({ProviderContainer container, SlimmDatabase db}) fixture;

  String get location => router.routeInformationProvider.value.uri.toString();
}

Future<_Rig> _pump(
  WidgetTester tester, {
  Brightness mode = Brightness.dark,
}) async {
  late _CountingVoiceController controller;
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith((ref) {
        controller = _CountingVoiceController(
          ref,
          VoiceState(
            channelId: 'c-main',
            state: VoiceSessionState.connected,
            connectedAt: DateTime.now().subtract(const Duration(seconds: 36)),
          ),
        );
        return controller;
      }),
    ],
  );
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final router = fixtureRouter(_elsewhere);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: mode == Brightness.dark
            ? buildTheme(Brightness.dark, AppTokens.dark)
            : buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
        builder: appChromeBuilder,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return _Rig(router, controller, fixture);
}

Future<void> _done(WidgetTester tester, _Rig rig) =>
    teardownFixture(tester, rig.fixture.container, rig.fixture.db);

Future<void> _tapAt(WidgetTester tester, _Rig rig, Offset at) async {
  rig.router.go(_elsewhere);
  await tester.pump(const Duration(milliseconds: 350));
  expect(rig.location, _elsewhere);
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets(
    'pressing the avatar, title, timer or bare bar returns to the call',
    (tester) async {
      final rig = await _pump(tester);
      final bar = tester.getRect(find.byType(VoiceStripIndicator));
      final mute = tester.getRect(find.byTooltip('Mute'));
      final title = tester.getCenter(find.byType(CallChannelName));
      final timer = tester.getCenter(
        find.textContaining(RegExp(r'^\d\d:\d\d$')),
      );
      final avatar = Offset(bar.left + 20, bar.center.dy);
      final gap = Offset((title.dx + mute.left) / 2 + 20, bar.center.dy);

      final probes = <String, Offset>{
        'avatar': avatar,
        'title': title,
        'timer': timer,
        'empty gap': gap,
        'top padding': Offset(bar.center.dx - 60, bar.top + 2),
        'bottom padding': Offset(bar.center.dx - 60, bar.bottom - 2),
        'left padding': Offset(bar.left + 2, bar.center.dy),
      };
      for (final e in probes.entries) {
        await _tapAt(tester, rig, e.value);
        expect(rig.location, _callRoute, reason: 'press on ${e.key}');
      }
      await _done(tester, rig);
    },
  );

  testWidgets('mute, deafen and leave act and do not navigate', (tester) async {
    final rig = await _pump(tester);
    for (final (tip, name) in [
      ('Mute', 'mute'),
      ('Deafen', 'deafen'),
      ('Leave call', 'leave'),
    ]) {
      await _tapAt(tester, rig, tester.getCenter(find.byTooltip(tip)));
      expect(rig.location, _elsewhere, reason: '$tip must not navigate');
      expect(rig.controller.calls.last, name);
    }
    await _done(tester, rig);
  });

  testWidgets('the small back arrow button is gone', (tester) async {
    final rig = await _pump(tester);
    expect(find.byTooltip('Back to the call'), findsNothing);
    expect(find.bySemanticsLabel('Back to the call'), findsNothing);
    await _done(tester, rig);
  });

  testWidgets('the strip is one semantic button, controls stay separate', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final rig = await _pump(tester);
    final strip = find.bySemanticsLabel(RegExp(r'^Return to call, '));
    expect(strip, findsOneWidget);
    final data = tester.getSemantics(strip);
    expect(data.label, matches(r'^Return to call, [^,]+, 00:3\d'));
    expect(data.flagsCollection.isButton, isTrue);
    for (final label in ['Mute', 'Deafen', 'Leave call']) {
      expect(find.bySemanticsLabel(label), findsOneWidget);
    }
    await _done(tester, rig);
    handle.dispose();
  });

  testWidgets('the press area is at least 44 tall', (tester) async {
    final rig = await _pump(tester);
    final bar = tester.getRect(find.byType(VoiceStripIndicator));
    expect(bar.height, greaterThanOrEqualTo(44));
    await _done(tester, rig);
  });

  testWidgets('Enter on the focused strip returns to the call', (tester) async {
    final rig = await _pump(tester);
    final inside = find.descendant(
      of: find.byType(CallStripPressArea),
      matching: find.byType(GestureDetector),
    );
    Focus.of(tester.element(inside)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 350));
    expect(rig.location, _callRoute);
    await _done(tester, rig);
  });

  testWidgets('a pointer over the strip raises its fill', (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final rig = await _pump(tester);
    Color? fill() =>
        (tester
                    .widget<AnimatedContainer>(
                      find.descendant(
                        of: find.byType(CallStripPressArea),
                        matching: find.byType(AnimatedContainer),
                      ),
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(fill(), Colors.transparent);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    final bar = tester.getRect(find.byType(VoiceStripIndicator));
    final over = Offset(bar.center.dx - 40, bar.center.dy);
    await mouse.moveTo(over);
    await tester.pump(const Duration(milliseconds: 350));
    expect(fill(), isNot(Colors.transparent));
    await mouse.removePointer();
    await _done(tester, rig);
  });
}
