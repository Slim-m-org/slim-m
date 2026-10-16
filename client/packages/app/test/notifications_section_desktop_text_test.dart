// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Linux desktop's notification rows: an honest status line where push
/// does not exist, and its own message text toggle, on by default.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/desktop_message_text_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
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

final _toggle = find.byWidgetPredicate(
  (w) =>
      w is AppToggle && w.semanticLabel == 'Show message text in notifications',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the desktop never says notifications are unavailable', (
    tester,
  ) async {
    if (!isLinuxHost) return;
    await tester.pumpWidget(_wrap(const NotificationsSection()));
    await tester.pumpAndSettle();

    expect(find.text('Not available on this device'), findsNothing);
    expect(find.text('Shown while slim-m is running'), findsOneWidget);
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
