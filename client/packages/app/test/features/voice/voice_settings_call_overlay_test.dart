// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call overlay preference: off by default, a corner once it is on,
/// persisted, and absent where the desktop cannot host the overlay.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart'
    show OverlayMonitor, OverlaySupport;

import 'voice_settings_screen_harness.dart';

const _toggleLabel = 'Show the call over my other windows';
const _enabledKey = 'slimm.voice.call_overlay_enabled';
const _cornerKey = 'slimm.voice.call_overlay_corner';

final _toggle = find.byWidgetPredicate(
  (w) => w is AppToggle && w.semanticLabel == _toggleLabel,
);
final _position = find.text('Overlay position');

const _screenKey = 'slimm.voice.call_overlay_screen';

OverlayMonitor _screen(int x) =>
    OverlayMonitor(x: x, y: 0, width: 1920, height: 1080, primary: x == 0);

Future<void> _pump(
  WidgetTester tester, {
  bool supported = true,
  List<OverlayMonitor> monitors = const [],
}) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    wrap(
      const VoiceSettingsBody(),
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: FakeSettingsSession()),
        ),
        screenOverlaySupportedProvider.overrideWithValue(supported),
        screenOverlaySupportProvider.overrideWith(
          (ref) async => OverlaySupport(supported: true, monitors: monitors),
        ),
      ],
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('is off by default, and the corner choice waits for it', (
    tester,
  ) async {
    await _pump(tester);
    expect(tester.widget<AppToggle>(_toggle).value, isFalse);
    expect(_position, findsNothing);
  });

  testWidgets('turning it on persists and offers the four corners', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_toggle);
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      (await SharedPreferences.getInstance()).getBool(_enabledKey),
      isTrue,
    );
    for (final label in [
      'Top left',
      'Top right',
      'Bottom left',
      'Bottom right',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('picking a corner persists it', (tester) async {
    SharedPreferences.setMockInitialValues({_enabledKey: true});
    await _pump(tester);
    await tester.tap(find.text('Bottom right'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (await SharedPreferences.getInstance()).getString(_cornerKey),
      'bottomRight',
    );
  });

  testWidgets('is absent, not disabled, where the overlay cannot be hosted', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({_enabledKey: true});
    await _pump(tester, supported: false);
    expect(find.text('Call overlay'), findsNothing);
    expect(_position, findsNothing);
  });

  testWidgets('drawing stays offered where the overlay cannot be hosted', (
    tester,
  ) async {
    await _pump(tester, supported: false);
    expect(find.text('Viewers draw on my screen'), findsOneWidget);
  });

  test('the settings index finds it', () {
    final hit = searchSettings('call overlay', personalSettingsIndex);
    expect(hit.map((e) => e.label), contains('Call overlay'));
  });

  testWidgets('with two screens the overlay screen can be picked', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({_enabledKey: true});
    await _pump(tester, monitors: [_screen(0), _screen(1920)]);
    await tester.pump();
    expect(find.text('Overlay screen'), findsOneWidget);
    await tester.tap(find.text('Screen 2'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (await SharedPreferences.getInstance()).getString(_screenKey),
      '1920,0,1920,1080',
    );

    await tester.tap(find.text('Automatic'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (await SharedPreferences.getInstance()).getString(_screenKey),
      isNull,
    );
  });

  testWidgets('with one screen there is nothing to pick', (tester) async {
    SharedPreferences.setMockInitialValues({_enabledKey: true});
    await _pump(tester, monitors: [_screen(0)]);
    await tester.pump();
    expect(find.text('Overlay position'), findsOneWidget);
    expect(find.text('Overlay screen'), findsNothing);
  });
}
