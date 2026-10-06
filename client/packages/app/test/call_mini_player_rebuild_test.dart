// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mini-player's video widget must not be torn down or rebuilt by the call
/// roster's constant churn (speaking flags, mic toggles) while the share runs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/call_mini_player.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

class _Counts {
  int inits = 0;
  int builds = 0;
  int disposes = 0;
}

final _counts = _Counts();

class _CountingView extends StatefulWidget {
  const _CountingView();

  @override
  State<_CountingView> createState() => _CountingViewState();
}

class _CountingViewState extends State<_CountingView> {
  @override
  void initState() {
    super.initState();
    _counts.inits++;
  }

  @override
  void dispose() {
    _counts.disposes++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _counts.builds++;
    return const SizedBox.expand();
  }
}

class _CountingSession extends FakeSession {
  @override
  Widget screenShareViewFor(String identity) => const _CountingView();
}

class _LiveVoiceController extends VoiceController {
  _LiveVoiceController(super.ref) : super(session: _CountingSession());

  void setState(VoiceState next) => state = next;
}

VoiceState _call({required bool speaking, required bool otherSpeaking}) =>
    VoiceState(
      channelId: 'c-main',
      state: VoiceSessionState.connected,
      participants: [
        VoiceParticipant(
          identity: 'u-ada',
          name: 'Ada',
          isSpeaking: speaking,
          isMuted: false,
          isLocal: false,
          isScreenSharing: true,
        ),
        VoiceParticipant(
          identity: 'u-me',
          name: 'Me',
          isSpeaking: otherSpeaking,
          isMuted: false,
          isLocal: true,
          isScreenSharing: false,
        ),
      ],
    );

void main() {
  setUpAll(loadRealFonts);

  testWidgets('roster churn over ten seconds never rebuilds the video view', (
    tester,
  ) async {
    late _LiveVoiceController controller;
    final fixture = await fixtureContainer(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => controller = _LiveVoiceController(ref),
        ),
      ],
    );
    tester.view.physicalSize = const Size(1400, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: fixtureRouter('/channels/c-general'),
          builder: appChromeBuilder,
        ),
      ),
    );
    controller.setState(_call(speaking: false, otherSpeaking: false));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(miniPlayerKey), findsOneWidget);
    final inits = _counts.inits;
    final builds = _counts.builds;
    expect(inits, 1);
    expect(builds, greaterThan(0));

    for (var i = 0; i < 100; i++) {
      controller.setState(_call(speaking: i.isEven, otherSpeaking: i % 3 == 0));
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(_counts.inits, inits, reason: 'the view was recreated');
    expect(_counts.disposes, 0, reason: 'the view was torn down');
    expect(
      _counts.builds,
      builds,
      reason: 'roster churn rebuilt the video view ${_counts.builds - builds}x',
    );
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('the card casts an AppShadows token, not its own shadow', (
    tester,
  ) async {
    late _LiveVoiceController controller;
    final fixture = await fixtureContainer(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => controller = _LiveVoiceController(ref),
        ),
      ],
    );
    tester.view.physicalSize = const Size(1400, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: fixtureRouter('/channels/c-general'),
          builder: appChromeBuilder,
        ),
      ),
    );
    controller.setState(_call(speaking: false, otherSpeaking: false));
    await tester.pump(const Duration(milliseconds: 350));

    final card = tester.widget<DecoratedBox>(find.byKey(miniPlayerKey));
    final decoration = card.decoration as BoxDecoration;
    expect(decoration.boxShadow, AppShadows.canvasTile);
    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
