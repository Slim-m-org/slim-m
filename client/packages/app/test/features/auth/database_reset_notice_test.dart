// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A device whose database key is gone says so and refetches, and a key store
/// that cannot be reached says so instead of opening a screen of nothing -
/// see docs/decisions/0042-encrypt-local-database.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/providers/database_key_store.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

Future<ProviderContainer> _pump(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: DatabaseResetNotice(child: Text('the shell')),
        ),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('shows nothing while no reset happened', (tester) async {
    await _pump(tester);

    expect(find.text('the shell'), findsOneWidget);
    expect(find.byType(AppCallout), findsNothing);
  });

  testWidgets('says the cache was cleared, and dismisses', (tester) async {
    final container = await _pump(tester);

    container.read(databaseResetProvider.notifier).state =
        DatabaseResetReason.keyMissing;
    await tester.pump();

    expect(find.textContaining('lost the key'), findsOneWidget);
    expect(find.text('the shell'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();

    expect(find.byType(AppCallout), findsNothing);
  });

  test('an unreachable key store reads as locked, not as a blank screen', () {
    final message = localStoreErrorMessage(
      const LocalDatabaseKeyUnavailable('locked'),
    );

    expect(message, contains('Nothing was deleted'));
    expect(
      localStoreErrorMessage(const DatabaseEncryptionUnavailable('x')),
      contains('cannot encrypt'),
    );
    expect(
      localStoreErrorMessage(StateError('x')),
      'Could not load this screen.',
    );
  });

  test('the database key round-trips through the platform key store', () async {
    final keys = KeyStoreDatabaseKey(InMemoryKeyStore());

    expect(await keys.read(), isNull);
    await keys.write('ab' * 32);

    expect(await keys.read(), 'ab' * 32);
  });
}
