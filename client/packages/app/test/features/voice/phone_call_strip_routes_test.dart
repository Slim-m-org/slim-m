// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone in a live call always has the strip or the call's own UI on screen.
///
/// Walks the screens reachable at 390x844 while a call is live: the owner saw
/// the app act as if he was not in a call after moving between screens.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_summary.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/dm_call_pane.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

const _inVoice = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
);
const _inDm = VoiceState(
  channelId: 'c-dm-ada',
  state: VoiceSessionState.connected,
);

/// Pumps the real shell at [location] and returns how many strips it shows.
Future<({int strips, int summaries, String subtitle})> _walk(
  WidgetTester tester,
  String location,
  VoiceState voice, {
  List<Override> extra = const [],
  String? pushAfter,
}) async {
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, voice),
      ),
      ...extra,
    ],
  );
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final router = fixtureRouter(location);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  if (pushAfter != null) {
    unawaited(router.push(pushAfter));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  final strips = find.byKey(voiceStripKey);
  final result = (
    strips: strips.evaluate().length,
    summaries: find.byKey(railCallSummaryKey).evaluate().length,
    subtitle: strips.evaluate().isEmpty
        ? ''
        : find
              .descendant(
                of: strips.last,
                matching: find.textContaining(RegExp('.')),
              )
              .evaluate()
              .map((e) => (e.widget as Text).data ?? '')
              .join('|'),
  );
  await teardownFixture(tester, fixture.container, fixture.db);
  return result;
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a DM chat shows the strip while its own call runs', (t) async {
    final r = await _walk(t, '/channels/c-dm-ada', _inDm);
    expect(r.strips, 1);
  });

  testWidgets('a DM call pane carries the call itself, so no strip', (t) async {
    final r = await _walk(
      t,
      '/channels/c-dm-ada',
      _inDm,
      extra: [dmCallOpenProvider.overrideWith((ref) => 'c-dm-ada')],
    );
    expect(r.strips, 0);
  });

  testWidgets('a voice channel chat over its call shows the strip', (t) async {
    final r = await _walk(
      t,
      '/channels/c-main',
      _inVoice,
      extra: [voiceChatPaneVisibleProvider.overrideWith((ref) => true)],
    );
    expect(r.strips, 1);
  });

  testWidgets('the call stage itself has no strip', (t) async {
    final r = await _walk(t, '/channels/c-main', _inVoice);
    expect(r.strips, 0);
  });

  testWidgets('the canvas of the call channel keeps its own dock', (t) async {
    final r = await _walk(
      t,
      '/channels/c-main',
      _inVoice,
      extra: [canvasOpenProvider.overrideWith((ref) => 'c-main')],
    );
    expect(r.strips, 0);
  });

  testWidgets('the channel list carries the call summary', (t) async {
    final r = await _walk(t, '/channels', _inVoice);
    expect(r.summaries, 1);
  });

  testWidgets('a pushed settings page shows the strip', (t) async {
    final r = await _walk(
      t,
      '/channels/c-general',
      _inVoice,
      pushAfter: '/settings',
    );
    expect(r.strips, greaterThanOrEqualTo(1));
  });

  testWidgets('an auto-rejoin keeps the strip, saying it is reconnecting', (
    t,
  ) async {
    const rejoining = VoiceState(
      channelId: 'c-main',
      state: VoiceSessionState.failed,
      rejoining: true,
    );
    final r = await _walk(t, '/channels/c-general', rejoining);
    expect(r.strips, 1);
    expect(r.subtitle, contains('Reconnecting'));
  });

  testWidgets('a banner-level reconnect keeps the strip', (t) async {
    const reconnecting = VoiceState(
      channelId: 'c-main',
      state: VoiceSessionState.connected,
      reconnecting: true,
    );
    final r = await _walk(t, '/channels/c-general', reconnecting);
    expect(r.strips, 1);
    expect(r.subtitle, contains('Reconnecting'));
  });

  testWidgets('no call shows nothing on any screen', (t) async {
    final r = await _walk(t, '/channels/c-dm-ada', const VoiceState());
    expect(r.strips, 0);
  });
}
