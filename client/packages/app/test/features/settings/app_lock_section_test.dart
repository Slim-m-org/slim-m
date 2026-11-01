// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Account & devices app-lock toggle: absent on an unsupported platform
/// rather than shown disabled, and actually wired to the preference
/// controller when it is shown.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/app_lock_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/app_lock_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

/// A real `AppLockWindowChannel` calls an unmocked platform channel, which
/// never resolves inside a `testWidgets` fake-async zone rather than failing
/// fast the way it does under a plain `test()`; see
/// `app_lock_gate_test.dart`'s own copy of this fake for the full story.
class _NoopAppLockWindowChannel implements AppLockWindowChannel {
  @override
  Future<void> setPrivacyShield(bool enabled) async {}
}

Future<ProviderContainer> _pump(WidgetTester tester, {bool? supported}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      appLockWindowChannelProvider.overrideWithValue(
        _NoopAppLockWindowChannel(),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ListView(children: [AppLockSection(supported: supported)]),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('renders nothing on an unsupported platform, not a disabled '
      'control', (tester) async {
    await _pump(tester, supported: false);

    expect(find.text('App lock'), findsNothing);
    expect(find.byType(AppToggle), findsNothing);
  });

  testWidgets('renders nothing on this suite\'s own host, which is Linux - '
      'the one platform `local_auth` cannot support', (tester) async {
    await _pump(tester);

    expect(find.text('App lock'), findsNothing);
  });

  testWidgets('on a supported platform, shows the toggle off by default and '
      'wires it to the preference controller', (tester) async {
    final container = await _pump(tester, supported: true);

    expect(find.text('App lock'), findsOneWidget);
    expect(container.read(appLockPreferenceProvider), isFalse);

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();

    expect(container.read(appLockPreferenceProvider), isTrue);
  });
}
