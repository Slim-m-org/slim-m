// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Storage's backup row and alert list: the last verified time, the failure, the stale warning,
/// recovered alerts, and the mute.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/admin_alerts/providers/admin_alerts.dart';
import 'package:slimm_app/src/features/admin_alerts/widgets/backup_status_card.dart';
import 'package:slimm_app/src/features/settings/screens/admin/storage_screen.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/mid_flight_capture.dart';
import '../../ui_snapshot_support.dart';
import 'alerts_harness.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<FakeServer> _pump(
  WidgetTester tester,
  FakeServer server, {
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  void Function(ProviderContainer container)? withContainer,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = server.container(permissions: manageServerBit);
  addTearDown(container.dispose);
  withContainer?.call(container);
  addTearDown(server.events.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness,
            brightness == Brightness.light ? AppTokens.light : AppTokens.dark,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: StoragePane()),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return server;
}

String _detail(WidgetTester tester) {
  final row = find.byKey(const Key('backup-status-row'));
  expect(row, findsOneWidget);
  return tester
      .widgetList<Text>(
        find.descendant(
          of: row,
          matching: find.byWidgetPredicate((w) => w is Text),
        ),
      )
      .map((t) => t.data ?? '')
      .join(' | ');
}

void main() {
  setUpAll(loadRealFonts);

  group('the backup line', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final fourteenHoursAgo = now.millisecondsSinceEpoch - 14 * 3600 * 1000;

    test('verified reads as an age and a size', () {
      final line = backupLine(
        api.SpaceBackupStatus(
          state: api.BackupState.verified,
          stale: false,
          verifiedAt: fourteenHoursAgo,
          verifiedBytes: 4096,
        ),
        now: now,
      );
      expect(line.detail, '14h ago, 4.0 KB');
      expect(line.warn, isFalse);
    });

    test('never and not set up are plain words, not warnings', () {
      for (final (state, text) in [
        (api.BackupState.never, 'Never'),
        (api.BackupState.notConfigured, 'Not set up'),
      ]) {
        final line = backupLine(
          api.SpaceBackupStatus(state: state, stale: false),
        );
        expect(line.detail, text);
        expect(line.warn, isFalse);
      }
    });

    test('a failure shows the error and keeps the last good time', () {
      final line = backupLine(
        api.SpaceBackupStatus(
          state: api.BackupState.failed,
          stale: false,
          error: 'drill: FAIL',
          verifiedAt: fourteenHoursAgo,
        ),
        now: now,
      );
      expect(line.detail, 'drill: FAIL. Last verified 14h ago.');
      expect(line.warn, isTrue);
    });

    test('past 48 hours it warns', () {
      final line = backupLine(
        api.SpaceBackupStatus(
          state: api.BackupState.verified,
          stale: true,
          verifiedAt: now.millisecondsSinceEpoch - 50 * 3600 * 1000,
        ),
        now: now,
      );
      expect(line.detail, '2d ago. Older than 48 hours.');
      expect(line.warn, isTrue);
    });
  });

  testWidgets('Storage shows Never before any backup ran', (tester) async {
    await _pump(tester, FakeServer());

    expect(_detail(tester), contains('Never'));
    expect(find.byKey(const Key('backup-status-warning')), findsNothing);
  });

  testWidgets('Storage shows a failure with the warning badge', (tester) async {
    final server = FakeServer()
      ..backup = {
        'state': 'failed',
        'stale': true,
        'error': 'backup: no database',
      };

    await _pump(tester, server);

    expect(_detail(tester), contains('backup: no database'));
    expect(find.byKey(const Key('backup-status-warning')), findsOneWidget);
  });

  testWidgets('open and recovered alerts are listed', (tester) async {
    final server = FakeServer()
      ..alerts = [
        alertJson(kind: 'backup', detail: 'The nightly backup failed.'),
        alertJson(raisedAt: 1699990000000, resolvedAt: 1699999000000),
      ];

    await _pump(tester, server);

    expect(find.byKey(const Key('admin-alert-backup-')), findsOneWidget);
    expect(
      find.byKey(const Key('admin-alert-recovered-disk_low-')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin-alert-recovered-backup-')),
      findsNothing,
    );
    expect(find.byKey(const Key('admin-alerts-empty')), findsNothing);
  });

  testWidgets('no alerts says so', (tester) async {
    await _pump(tester, FakeServer());

    expect(find.byKey(const Key('admin-alerts-empty')), findsOneWidget);
  });

  testWidgets('the mute switch saves and the list reloads', (tester) async {
    final server = FakeServer();
    await _pump(tester, server);

    final toggle = find.bySemanticsLabel('Mute server alerts');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await _settle(tester);

    expect(server.muted, isTrue);
    expect(server.requests, contains('PUT /space/alerts/mute'));
    expect(server.requests.where((r) => r == 'GET /space/alerts').length, 2);
  });

  testWidgets('a mute that fails says so inline and offers a retry', (
    tester,
  ) async {
    final server = FakeServer()..failMute = true;
    await _pump(tester, server);

    final toggle = find.bySemanticsLabel('Mute server alerts');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await _settle(tester);

    final error = find.byKey(const Key('admin-alerts-mute-error'));
    expect(error, findsOneWidget);
    expect(
      find.descendant(
        of: error,
        matching: find.textContaining('Could not change the alert mute'),
      ),
      findsOneWidget,
    );

    server.failMute = false;
    final retry = find.descendant(of: error, matching: find.text('Retry'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await _settle(tester);

    expect(server.muted, isTrue);
    expect(error, findsNothing);
  });

  testWidgets('leaving Storage mid-save still refreshes the alert list', (
    tester,
  ) async {
    final server = FakeServer()..muteGate = Completer<void>();
    late final ProviderContainer container;
    await _pump(
      tester,
      server,
      withContainer: (made) {
        container = made;
        made.listen(adminAlertsProvider, (_, _) {});
      },
    );

    final toggle = find.bySemanticsLabel('Mute server alerts');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await _settle(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    server.muteGate!.complete();
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(server.requests.where((r) => r == 'GET /space/alerts').length, 2);
  });

  const viewports = {'phone': Size(390, 1500), 'desktop': Size(1440, 1100)};
  for (final viewport in viewports.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('storage at ${viewport.key} ${brightness.name} fits', (
        tester,
      ) async {
        final server = FakeServer()
          ..backup = {
            'state': 'failed',
            'stale': true,
            'error': 'drill: attachments/9f3c missing from the backup mirror',
            'verified_at':
                DateTime.now().millisecondsSinceEpoch - 60 * 3600 * 1000,
            'verified_bytes': 48234496,
          }
          ..alerts = [
            alertJson(kind: 'backup', detail: 'The nightly backup failed.'),
            alertJson(
              kind: 'module_breaker',
              subject: 'tally',
              detail: 'Tally was turned off after 5 failed runs in a row.',
            ),
            alertJson(
              kind: 'push_relay',
              detail:
                  'The push relay has not answered the last 3 notifications.',
              raisedAt: 1699990000000,
              resolvedAt: 1699999000000,
            ),
          ];
        await _pump(
          tester,
          server,
          size: viewport.value,
          brightness: brightness,
        );

        final name = 'storage-alerts-${viewport.key}-${brightness.name}';
        await expectSettled(tester, name);
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, name);
      });
    }
  }
}
