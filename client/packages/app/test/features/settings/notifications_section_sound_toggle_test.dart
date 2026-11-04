// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message-sounds toggle `NotificationsSection` added beside the push
/// registration status: it persists, the same shape
/// `voice_settings_screen_test.dart` already proves for the call sounds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_settings.dart';
import 'package:slimm_app/src/features/settings/providers/ui_sound_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_app/src/features/modules/providers/module_sound_settings.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

class _FailedPush extends PushController {
  _FailedPush(super.ref) {
    state = PushStatus.serverError;
  }
}

Widget _wrap(Widget child, {bool failed = false}) => UncontrolledProviderScope(
  container: ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      if (failed) pushControllerProvider.overrideWith(_FailedPush.new),
    ],
  )..read(preferencesProvider),
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the message-sounds toggle starts on', (tester) async {
    await tester.pumpWidget(_wrap(const NotificationsSection()));
    await tester.pumpAndSettle();

    final toggle = tester.widget<AppToggle>(
      find.byWidgetPredicate(
        (w) =>
            w is AppToggle &&
            w.semanticLabel == 'Play a sound for messages, mentions and errors',
      ),
    );
    expect(toggle.value, isTrue);
  });

  testWidgets('turning message sounds off persists it', (tester) async {
    await tester.pumpWidget(_wrap(const NotificationsSection()));
    await tester.pumpAndSettle();

    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle &&
          w.semanticLabel == 'Play a sound for messages, mentions and errors',
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('slimm.notifications.message_sounds_enabled'),
      isFalse,
    );
  });

  testWidgets('a healthy or pending push state shows no banner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const NotificationsSection(hasPushChannel: true)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ListTile), findsNothing);
    expect(find.byKey(NotificationsSection.bannerKey), findsNothing);
  });

  testWidgets('a push failure shows the banner, a host without push never', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const NotificationsSection(hasPushChannel: true), failed: true),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(NotificationsSection.bannerKey), findsOneWidget);
    expect(find.text('Could not reach the server'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(const NotificationsSection(hasPushChannel: false), failed: true),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(NotificationsSection.bannerKey), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 60));
  });

  Finder toggleLabelled(String label) =>
      find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == label);

  testWidgets('the interface sounds toggle persists independently', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const NotificationsSection()));
    await tester.pumpAndSettle();

    final toggle = toggleLabelled(
      'Play soft sounds for sending, joining and muting',
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(uiSoundsEnabledKey), isFalse);
    expect(prefs.getBool(messageSoundsEnabledKey), isNull);
  });

  testWidgets(
    'the haptics toggle switches AppHaptics without touching sounds',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        AppHaptics.enabled = true;
      });
      await tester.pumpWidget(_wrap(const NotificationsSection()));
      await tester.pumpAndSettle();

      final toggle = toggleLabelled('Vibrate for taps, holds and alerts');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(hapticsEnabledKey), isFalse);
      expect(prefs.getBool(messageSoundsEnabledKey), isNull);
      expect(AppHaptics.enabled, isFalse);
      debugDefaultTargetPlatformOverride = null;
      AppHaptics.enabled = true;
    },
  );

  testWidgets('the haptics toggle is absent on a desktop', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_wrap(const NotificationsSection()));
    await tester.pumpAndSettle();

    expect(toggleLabelled('Vibrate for taps, holds and alerts'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the dock module sounds toggle persists, both ways', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const NotificationsSection()));
    await tester.pump(const Duration(milliseconds: 300));
    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle && w.semanticLabel == 'Let modules play sound effects',
    );
    final prefs = await SharedPreferences.getInstance();

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 300));
    expect(prefs.getBool(moduleSoundEnabledKey), isFalse);

    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 300));
    expect(prefs.getBool(moduleSoundEnabledKey), isTrue);
  });
}
