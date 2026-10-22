// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `appReadyProvider`'s own gate: [SlimMApp] shows the startup screen while
/// it is false and swaps to the real app once it flips true - main.dart's
/// own async-bootstrap sequencing, checked without ever calling `main()`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/main.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('defaults to ready, matching every existing test that never '
      'touches this provider', (tester) async {
    final container = _container();

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SlimMApp()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StartupScreen), findsNothing);
    expect(find.byType(OnboardingScreen), findsOneWidget);
  });

  testWidgets('shows the startup screen while not ready, and swaps to the '
      'real app once it is', (tester) async {
    final container = _container();
    container.read(appReadyProvider.notifier).state = false;

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SlimMApp()),
    );
    await tester.pump();

    expect(find.byType(StartupScreen), findsOneWidget);

    container.read(appReadyProvider.notifier).state = true;
    await tester.pumpAndSettle();

    expect(find.byType(StartupScreen), findsNothing);
  });

  testWidgets('the startup screen shows startupStatusProvider\'s live value, '
      'the seam a future update-progress flow reuses', (tester) async {
    final container = _container();
    container.read(appReadyProvider.notifier).state = false;
    container.read(startupStatusProvider.notifier).state = 'Connecting';

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SlimMApp()),
    );
    await tester.pump();

    expect(find.text('Connecting'), findsOneWidget);

    container.read(startupStatusProvider.notifier).state = 'Downloading update';
    await tester.pump();

    expect(find.text('Downloading update'), findsOneWidget);
  });
}
