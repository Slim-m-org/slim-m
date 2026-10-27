// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `appReadyProvider`'s own gate: [SlimMApp] shows the startup screen while
/// it is false and swaps to the real app once it flips true - main.dart's
/// own async-bootstrap sequencing, checked without ever calling `main()`.
library;

import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/main.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
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

  testWidgets('a phone shows the lattice splash while not ready, and no '
      'second splash exists', (tester) async {
    final container = _container();
    container.read(appReadyProvider.notifier).state = false;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SlimMApp(isDesktopOverride: false),
      ),
    );
    await tester.pump();

    expect(find.byType(StartupScreen), findsOneWidget);
  });

  testWidgets('a signed-in phone keeps the same splash up until the first '
      'catch-up lands, then hands straight to the app', (tester) async {
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    container
        .read(sessionProvider)
        .adopt(
          const TokenPair(
            userId: 'u',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 1 << 50,
          ),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SlimMApp(isDesktopOverride: false),
      ),
    );
    await tester.pump();
    expect(find.byType(StartupScreen), findsOneWidget);

    container.read(initialSyncCompleteProvider.notifier).state = true;
    await tester.pump();
    expect(find.byType(StartupScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  testWidgets('a signed-out phone is not held past bootstrap', (tester) async {
    final container = _container();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SlimMApp(isDesktopOverride: false),
      ),
    );
    await tester.pump();

    expect(find.byType(StartupScreen), findsNothing);
  });
}
