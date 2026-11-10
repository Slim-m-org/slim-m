// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures for the Space settings panes that only the two-pane desktop
/// layout or a dark phone capture showed: voice, export, audit log, customize,
/// storage and server metrics, each as the pane the settings route opens.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/data_exports.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/routing/routes.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_settings_personal_and_space_photo.dart';
import 'ui_review_settings_personal_and_space_space_data.dart';
import 'ui_review_settings_personal_and_space_support.dart';

String _route(String pane) => Routes.spaceSettingsPane(pane);

Future<void> _runUplink(WidgetTester tester) async {
  final run = find.byKey(const Key('uplink-test-run'));
  await tester.ensureVisible(run);
  await tester.pump();
  await tester.tap(run);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _settleBanner(WidgetTester tester) async {
  await settleImages(tester);
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    for (final (state, overrides, after)
        in <(String, ReviewAnswerSet, ReviewAfter?)>[
          ('default', voiceAnswers(results: const []), null),
          ('uplink-running', voiceAnswers(results: const []), _runUplink),
          ('uplink-result', voiceAnswers(results: uplinkResults), null),
        ]) {
      testWidgets('settings-space-voice $state at $viewport', (tester) async {
        final hold = Completer<void>();
        await reviewRoute(
          tester,
          surface: 'settings-space-voice',
          state: state,
          viewport: viewport,
          route: _route('space-voice'),
          overrides: [
            reviewApi({
              ...overrides,
              if (state == 'uplink-running')
                'POST /space/uplink-test': (request) async {
                  await hold.future;
                  return jsonAnswer(uplinkResults.first)(request);
                },
            }),
          ],
          afterSettle: after,
          beforeTeardown: (t) async {
            hold.complete();
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await t.pump(const Duration(milliseconds: 100));
          },
        );
      });
    }

    for (final (state, jobs) in <(String, List<api.DataExport>)>[
      ('none', const []),
      ('running', [runningExport]),
      ('ready', [readyExport]),
    ]) {
      testWidgets('settings-space-export $state at $viewport', (tester) async {
        await reviewRoute(
          tester,
          surface: 'settings-space-export',
          state: state,
          viewport: viewport,
          route: _route('export'),
          overrides: [dataExportsProvider.overrideWith((ref) async => jobs)],
        );
      });
    }

    for (final (state, entries) in <(String, List<Map<String, Object?>>)>[
      ('entries', auditEntries),
      ('empty', const []),
    ]) {
      testWidgets('settings-space-audit-log $state at $viewport', (
        tester,
      ) async {
        await reviewRoute(
          tester,
          surface: 'settings-space-audit-log',
          state: state,
          viewport: viewport,
          route: _route('audit-log'),
          overrides: [
            reviewApi({'/space/audit-log': jsonAnswer(entries)}),
          ],
        );
      });
    }

    testWidgets('settings-space-customize default at $viewport', (
      tester,
    ) async {
      final banner = await reviewPhotoPng(tester, 1280, 427);
      await reviewRoute(
        tester,
        surface: 'settings-space-customize',
        state: 'default',
        viewport: viewport,
        route: _route('customize'),
        overrides: [
          reviewApi({
            '/space/settings': jsonAnswer(customizedSpace),
            '/space/banner': (_) => http.Response.bytes(
              banner,
              200,
              headers: {'content-type': 'image/png'},
            ),
          }),
        ],
        afterSettle: _settleBanner,
      );
    });

    testWidgets('settings-space-storage default at $viewport', (tester) async {
      await reviewRoute(
        tester,
        surface: 'settings-space-storage',
        state: 'default',
        viewport: viewport,
        route: _route('storage'),
        overrides: [
          reviewApi({'/space/storage': jsonAnswer(storageReport)}),
        ],
      );
    });

    testWidgets('settings-space-server-metrics default at $viewport', (
      tester,
    ) async {
      await reviewRoute(
        tester,
        surface: 'settings-space-server-metrics',
        state: 'default',
        viewport: viewport,
        route: _route('server-metrics'),
        overrides: [
          reviewApi({'/space/setup': jsonAnswer(setupReport)}),
          serverMetricsProvider.overrideWith((ref) async => metrics),
        ],
      );
    });
  }
}
