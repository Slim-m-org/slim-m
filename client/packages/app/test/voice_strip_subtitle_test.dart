// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The collapsed call strip's subtitle must not start with a bare separator.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

Future<void> _pumpStrip(WidgetTester tester, VoiceState voice) async {
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, voice),
      ),
    ],
  );
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: VoiceStripIndicator()),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

Iterable<String> _texts(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '');

void main() {
  setUpAll(loadRealFonts);

  testWidgets('no timer yet: subtitle has no leading separator', (
    tester,
  ) async {
    await _pumpStrip(
      tester,
      const VoiceState(channelId: 'c-main', state: VoiceSessionState.connected),
    );
    expect(_texts(tester), contains('Audio only'));
    expect(_texts(tester).where((t) => t.trimLeft().startsWith('-')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with a timer the separator sits between timer and label', (
    tester,
  ) async {
    await _pumpStrip(
      tester,
      VoiceState(
        channelId: 'c-main',
        state: VoiceSessionState.connected,
        connectedAt: DateTime.now(),
      ),
    );
    expect(_texts(tester), contains(' - audio only'));
    await tester.pumpWidget(const SizedBox());
  });
}
