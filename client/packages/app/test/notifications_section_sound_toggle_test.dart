// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message-sounds toggle `NotificationsSection` added beside the push
/// registration status: it persists, the same shape
/// `voice_settings_screen_test.dart` already proves for the call sounds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/notification_status_banner.dart';
import 'package:slimm_app/src/widgets/personal_status_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

Widget _wrap(Widget child) => UncontrolledProviderScope(
  container: ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
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

  testWidgets('the push status is a banner, never a bare ListTile', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const NotificationsSection()));
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(NotificationStatusBanner), findsOneWidget);
  });
}
