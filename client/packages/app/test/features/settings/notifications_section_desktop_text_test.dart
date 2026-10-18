// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop's notification rows: no push status where push does not exist,
/// and its own message text toggle, on by default.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/desktop_message_text_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/notification_status_banner.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
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

final _toggle = find.byWidgetPredicate(
  (w) =>
      w is AppToggle && w.semanticLabel == 'Show message text in notifications',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a device without push shows no push status at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const NotificationsSection(hasPushChannel: false)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NotificationStatusBanner), findsNothing);
    expect(find.text('Shown while slim-m is running'), findsNothing);
  });

  testWidgets('a phone still shows whether push reaches it', (tester) async {
    await tester.pumpWidget(
      _wrap(const NotificationsSection(hasPushChannel: true)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NotificationStatusBanner), findsOneWidget);
  });

  testWidgets('message text starts on, and turning it off persists', (
    tester,
  ) async {
    if (!isLinuxHost) return;
    await tester.pumpWidget(_wrap(const NotificationsSection()));
    await tester.pumpAndSettle();
    expect(tester.widget<AppToggle>(_toggle).value, isTrue);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(desktopMessageTextKey), isFalse);
  });
}
