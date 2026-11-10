// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures for the account-side personal sheets: two-factor setup,
/// the notification schedule time picker, the Troubleshooting pane and the two
/// small menus (background picture, theme editor).
///
/// The phone debug log is the routed screen the row pushes; on desktop it is
/// the pane's inline view, which is what `debug-log-inline` names.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/features/settings/providers/connection_test_controller.dart';
import 'package:slimm_app/src/features/settings/providers/notification_preference_controller.dart';
import 'package:slimm_app/src/features/settings/providers/notification_schedule_controller.dart';
import 'package:slimm_app/src/features/settings/widgets/background_picture_menu.dart';
import 'package:slimm_app/src/features/settings/widgets/totp_enrol_sheet.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';

import '../features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController;
import '../ui_snapshot_support.dart';
import 'ui_review_settings_personal_and_space_probe.dart';
import 'ui_review_settings_personal_and_space_support.dart';

final _idleVoice = voiceControllerProvider.overrideWith(
  (ref) => SnapshotVoiceController(ref, const VoiceState()),
);

final _days = [
  for (var weekday = 0; weekday < 5; weekday++)
    api.NotificationScheduleDay(
      weekday: weekday,
      startMinute: 540,
      endMinute: 1020,
    ),
];

final _scheduleOverrides = [
  _idleVoice,
  notificationScheduleProvider.overrideWith(
    (ref) async => api.NotificationSchedule(
      timezone: 'UTC',
      days: _days,
      offHoursMode: api.OffHoursMode.mentions,
      snoozeUntil: null,
      allowedUserIds: const ['user-ada'],
      allowedChannelIds: const ['c-design'],
    ),
  ),
  notificationPreferenceProvider.overrideWith(
    (ref) async => api.NotificationPreference.everything,
  ),
];

Future<void> _openHoursPicker(WidgetTester tester) async {
  final row = find.text('Hours');
  await tester.ensureVisible(row);
  await tester.pump();
  await tester.tap(row);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _openEndPicker(WidgetTester tester) async {
  await _openHoursPicker(tester);
  await tester.tap(find.text('OK'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Finder get _field => find.byWidgetPredicate((w) => w is EditableText);

Future<void> _enrolTo(WidgetTester tester, {String? code}) async {
  await tester.enterText(_field.first, 'correct horse');
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  if (code == null) return;
  await tester.enterText(_field.last, code);
  await tester.pump();
}

Future<void> _submitCode(WidgetTester tester) async {
  final submit = find.text('Turn on').last;
  await tester.ensureVisible(submit);
  await tester.pump();
  await tester.tap(submit);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
}

final _totpApi = reviewApi({
  'POST /auth/totp/enrol': jsonAnswer({
    'secret': 'JBSWY3DPEHPK3PXP',
    'provisioning_uri':
        'otpauth://totp/slim-m:nick?secret=JBSWY3DPEHPK3PXP&issuer=slim-m',
  }),
  'POST /auth/totp/confirm': jsonAnswer({
    'recovery_codes': [
      'k7f2-m9qx-31ab',
      'p4dz-8wrt-90cd',
      'h2ys-6ncv-47ef',
      'x8bj-3tgq-52gh',
      'r5mw-1lze-68ij',
      'c9ua-7pks-04kl',
    ],
  }),
});

final _wrongCodeApi = reviewApi({
  'POST /auth/totp/enrol': jsonAnswer({
    'secret': 'JBSWY3DPEHPK3PXP',
    'provisioning_uri':
        'otpauth://totp/slim-m:nick?secret=JBSWY3DPEHPK3PXP&issuer=slim-m',
  }),
  'POST /auth/totp/confirm': jsonAnswer({
    'error': 'that code is not valid',
  }, 400),
});

DebugLog _populated() => DebugLog()
  ..record(
    'voice',
    'Reconnected to the SFU after a 2s drop',
    level: DiagnosticSeverity.info,
  )
  ..record(
    'platform',
    'Per-participant volume is unsupported on this platform',
    level: DiagnosticSeverity.warning,
    detail: 'The audio backend reports no per-stream gain.',
  )
  ..record(
    'flutter',
    'A RenderFlex overflowed by 12 pixels on the right',
    detail:
        '#0  RenderFlex.performLayout (package:flutter/...)\n'
        '#1  RenderObject.layout (package:flutter/...)',
  );

Future<void> _runConnectionTest(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('Run'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pump();
}

Future<void> _openDebugLog(WidgetTester tester) async {
  final row = find.text('Debug log').first;
  await tester.ensureVisible(row);
  await tester.pump();
  await tester.tap(row);
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.tap(find.textContaining('Per-participant volume'));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    for (final (state, api, code, submit) in [
      ('qr', _totpApi, null, false),
      ('code', _totpApi, '123456', false),
      ('recovery-codes', _totpApi, '123456', true),
      ('wrong-code', _wrongCodeApi, '000000', true),
    ]) {
      testWidgets('sheet-totp-enrol $state at $viewport', (tester) async {
        await reviewOverlay(
          tester,
          surface: 'sheet-totp-enrol',
          state: state,
          viewport: viewport,
          overrides: [api],
          open: (context, ref) => showTotpEnrolSheet(context, ref),
          afterOpen: (t) async {
            await _enrolTo(t, code: code);
            if (submit) await _submitCode(t);
          },
        );
      });
    }

    for (final (state, after) in [
      ('start', _openHoursPicker),
      ('end', _openEndPicker),
    ]) {
      testWidgets('dialog-time-picker $state at $viewport', (tester) async {
        await reviewRoute(
          tester,
          surface: 'dialog-time-picker',
          state: state,
          viewport: viewport,
          route: Routes.personalSettingsPane('notifications'),
          overrides: _scheduleOverrides,
          afterSettle: after,
        );
      });
    }

    final troubleshooting =
        <(String, ReviewProbes Function(Completer<void>)?, ReviewAfter?)>[
          ('default', null, null),
          ('connection-test-running', runningProbes, _runConnectionTest),
          ('connection-test-result', resultProbes, _runConnectionTest),
        ];
    for (final (state, probes, after) in troubleshooting) {
      testWidgets('settings-personal-troubleshooting $state at $viewport', (
        tester,
      ) async {
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        await reviewRoute(
          tester,
          surface: 'settings-personal-troubleshooting',
          state: state,
          viewport: viewport,
          route: Routes.personalSettingsPane('troubleshooting'),
          overrides: [
            _idleVoice,
            if (probes != null)
              connectionProbesProvider.overrideWithValue(() => probes(gate)),
            connectionLanInUseProvider.overrideWithValue(() => true),
          ],
          afterSettle: after,
        );
      });
    }

    testWidgets('settings-personal-troubleshooting debug-log-inline at '
        '$viewport', (tester) async {
      await reviewRoute(
        tester,
        surface: 'settings-personal-troubleshooting',
        state: 'debug-log-inline',
        viewport: viewport,
        route: Routes.personalSettingsPane('troubleshooting'),
        overrides: [
          _idleVoice,
          debugLogProvider.overrideWith((ref) => _populated()),
        ],
        afterSettle: _openDebugLog,
      );
    });

    testWidgets('menu-background-picture default at $viewport', (tester) async {
      await reviewOverlay(
        tester,
        surface: 'menu-background-picture',
        state: 'default',
        viewport: viewport,
        freshPerTheme: true,
        open: (context, ref) =>
            showBackgroundPictureMenu(context, canRemove: true),
      );
    });

    for (final (state, key) in const [
      ('editor-overflow', 'theme-editor-menu'),
      ('start-from', 'theme-editor-start-from'),
    ]) {
      testWidgets('menu-theme-actions $state at $viewport', (tester) async {
        await reviewRoute(
          tester,
          surface: 'menu-theme-actions',
          state: state,
          viewport: viewport,
          route: Routes.personalThemeEditor,
          freshPerTheme: true,
          afterSettle: (t) async {
            await t.tap(find.byKey(Key(key)));
            await t.pump();
            await t.pump(const Duration(milliseconds: 350));
          },
        );
      });
    }
  }
}
