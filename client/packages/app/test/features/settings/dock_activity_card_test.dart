// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Activity card on an installed module's Dock screen: when it last ran,
/// whether it is failing and why, and the stored-data allowance with its reset.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_activity_card.dart';
import 'package:slimm_design_system/design_system.dart';

final _now = DateTime.fromMillisecondsSinceEpoch(10 * 3600 * 1000);

api.DockRunStat _stat({
  int? failingSince,
  String? error,
  int failures = 0,
  int? lastFuel,
  int maxFuel = 0,
}) => api.DockRunStat(
  lastFuelUsed: lastFuel,
  maxFuelUsed: maxFuel,
  command: 'post',
  runCount: 4,
  failureCount: failures,
  lastRunAt: _now.millisecondsSinceEpoch - 5 * 60 * 1000,
  failingSince: failingSince,
  lastError: error,
  lastDurationMs: 10,
  maxDurationMs: 20,
);

Future<void> _pump(
  WidgetTester tester, {
  List<api.DockRunStat> stats = const [],
  api.DockStorage? storage,
  bool keepsData = true,
  VoidCallback? onClear,
  int fuelLimit = 0,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: DockActivityCard(
        stats: stats,
        storage: storage,
        keepsData: keepsData,
        onClearStorage: onClear ?? () {},
        fuelLimit: fuelLimit,
        now: _now,
      ),
    ),
  ),
);

Finder _badge(String label) =>
    find.byWidgetPredicate((w) => w is AppBadge && w.label == label);

void main() {
  testWidgets('a module that never ran says so', (tester) async {
    await _pump(tester);
    expect(find.text('It has not run yet.'), findsOneWidget);
  });

  testWidgets('a healthy command shows its last run and counts', (
    tester,
  ) async {
    await _pump(tester, stats: [_stat(failures: 1)]);
    expect(find.text('Last ran 5m ago. 4 runs, 1 failed.'), findsOneWidget);
    expect(_badge('Failing'), findsNothing);
  });

  testWidgets('a command shows the fuel its last and its heaviest run burned', (
    tester,
  ) async {
    await _pump(
      tester,
      stats: [_stat(lastFuel: 1200000, maxFuel: 3400000)],
      fuelLimit: 50000000,
    );
    expect(
      find.text(
        'Last ran 5m ago. 4 runs, 0 failed. '
        'Fuel: 1.2M last run, 3.4M most, of 50M.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a run with no fuel reading shows only the heaviest one', (
    tester,
  ) async {
    await _pump(tester, stats: [_stat(maxFuel: 800)], fuelLimit: 50000000);
    expect(find.textContaining('Fuel: 800 most, of 50M.'), findsOneWidget);
    expect(find.textContaining('last run'), findsNothing);
  });

  testWidgets('a command that has used no fuel shows no fuel line', (
    tester,
  ) async {
    await _pump(tester, stats: [_stat()]);
    expect(find.textContaining('Fuel'), findsNothing);
  });

  testWidgets('a failing command still shows its fuel after the error', (
    tester,
  ) async {
    await _pump(
      tester,
      stats: [
        _stat(
          failingSince: _now.millisecondsSinceEpoch - 3600 * 1000,
          error: 'exceeded its fuel (CPU) budget',
          lastFuel: 50000000,
          maxFuel: 50000000,
        ),
      ],
      fuelLimit: 50000000,
    );
    expect(
      find.textContaining(
        'exceeded its fuel (CPU) budget Fuel: 50M last run, 50M most, of 50M.',
      ),
      findsOneWidget,
    );
  });

  test('fuel reads in thousands and millions', () {
    expect(dockFuel(12), '12');
    expect(dockFuel(1500), '1.5k');
    expect(dockFuel(340000), '340k');
    expect(dockFuel(1200000), '1.2M');
    expect(dockFuel(50000000), '50M');
  });

  testWidgets('a failing scheduled command shows since when and the error', (
    tester,
  ) async {
    await _pump(
      tester,
      stats: [
        _stat(
          failingSince: _now.millisecondsSinceEpoch - 3 * 3600 * 1000,
          error: 'message.post rate limit reached',
          failures: 2,
        ),
      ],
    );
    expect(
      find.text('Failing since 3h ago: message.post rate limit reached'),
      findsOneWidget,
    );
    expect(_badge('Failing'), findsOneWidget);
  });

  testWidgets('stored data shows usage and Clear empties it', (tester) async {
    var cleared = 0;
    await _pump(
      tester,
      storage: const api.DockStorage(
        entries: 12,
        bytes: 3100,
        maxEntries: 256,
        maxBytes: 65536,
      ),
      onClear: () => cleared++,
    );
    expect(find.text('12 of 256 entries, 3.0 KB of 64 KB'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Clear'));
    expect(cleared, 1);
  });

  testWidgets('Clear is off when nothing is stored, and absent without kv', (
    tester,
  ) async {
    await _pump(
      tester,
      storage: const api.DockStorage(
        entries: 0,
        bytes: 0,
        maxEntries: 256,
        maxBytes: 65536,
      ),
    );
    final button = tester.widget<AppButton>(
      find.widgetWithText(AppButton, 'Clear'),
    );
    expect(button.disabled, isTrue);

    await _pump(tester, keepsData: false);
    expect(find.text('Stored data'), findsNothing);
  });

  test('bytes read in the coarsest true unit', () {
    expect(dockBytes(12), '12 bytes');
    expect(dockBytes(3100), '3.0 KB');
    expect(dockBytes(65536), '64 KB');
  });
}
