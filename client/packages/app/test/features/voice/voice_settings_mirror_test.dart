// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Mirror my view": on by default, persisted, shown in the camera settings
/// with its note that others see you unmirrored, and applied app-wide.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

const _key = 'slimm.voice.mirror_self_view';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the camera settings offer it, on, with the note', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
    );
    await tester.pumpAndSettle();

    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle && w.semanticLabel == 'Mirror your own camera preview',
    );
    await tester.scrollUntilVisible(
      toggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<AppToggle>(toggle).value, isTrue);
    expect(find.text('Mirror my view'), findsOneWidget);
    expect(find.text('Others always see you unmirrored.'), findsOneWidget);
  });

  testWidgets('turning it off persists', (tester) async {
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
    );
    await tester.pumpAndSettle();
    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle && w.semanticLabel == 'Mirror your own camera preview',
    );
    await tester.scrollUntilVisible(
      toggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect((await SharedPreferences.getInstance()).getBool(_key), isFalse);
  });

  testWidgets('the stored choice reaches every camera view', (tester) async {
    SharedPreferences.setMockInitialValues({_key: false});
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    addTearDown(container.dispose);
    late bool seen;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          builder: appChromeBuilder,
          home: Builder(
            builder: (context) {
              seen = MirrorSelfViewScope.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(voiceSettingsControllerProvider).mirrorSelfView,
      false,
    );
    expect(seen, isFalse);
  });
}
