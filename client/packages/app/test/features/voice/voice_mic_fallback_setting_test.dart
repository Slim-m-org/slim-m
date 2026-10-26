// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "switch if my microphone stops working" preference and the notice the
/// call shows once it has switched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/mic_failure_providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/mic_failure_banner.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_settings_screen_harness.dart';

const _label = 'Switch microphone if mine stops working';
const _key = 'slimm.voice.mic_fallback_enabled';

Finder get _toggle =>
    find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == _label);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'is on by default; turning it off persists and reaches the call',
    (tester) async {
      final session = FakeSession();
      await tester.pumpWidget(
        wrap(
          const VoiceSettingsBody(),
          overrides: [
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: session),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        _toggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<AppToggle>(_toggle).value, isTrue);
      expect(
        find.text('Use another microphone when yours goes silent.'),
        findsOneWidget,
      );

      await tester.tap(_toggle);
      await tester.pumpAndSettle();

      expect(tester.widget<AppToggle>(_toggle).value, isFalse);
      expect((await SharedPreferences.getInstance()).getBool(_key), isFalse);
      expect(session.lastMicFallbackEnabled, isFalse);
    },
  );

  testWidgets('the call names the microphone it switched to, until dismissed', (
    tester,
  ) async {
    final session = FakeSession()..micFallbackNotice = 'Desk mic';
    await tester.pumpWidget(
      wrap(
        const MicFailureBanner(),
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: session),
          ),
          micFailureProvider.overrideWith((ref) => const Stream.empty()),
        ],
      ),
    );
    await tester.pump();
    expect(
      find.text('Your microphone went silent. Switched to Desk mic.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Dismiss'));
    await tester.pump();

    expect(find.textContaining('Switched to'), findsNothing);
    expect(session.micFallbackNotice, isNull);
  });
}
