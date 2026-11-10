// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The overlays the app mounts above every screen: toasts, the pill for a
/// call held on another server, and the Windows move-and-update question.
/// The desktop captures carry the frameless title bar, as the running app does.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/windows_adopt_confirm.dart';
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_design_system/design_system.dart';

import '../features/voice/voice_snapshot_fixtures.dart';
import '../ui_snapshot_support.dart';
import 'app_chrome_support.dart';

List<Override> _chrome(String viewport) =>
    viewport == 'desktop' ? desktopChromeOverrides() : const [];

/// Sticky, so a capture never races the auto-dismiss timer.
void _toast(
  ChromeApp app,
  String message, [
  AppToastSeverity severity = AppToastSeverity.info,
]) => app.container
    .read(toastsProvider.notifier)
    .show(message, severity: severity, duration: Duration.zero);

Future<void> _toasts(
  WidgetTester tester,
  String viewport,
  String state,
  void Function(ChromeApp app) show, {
  String route = '/channels/c-general',
  List<Override> overrides = const [],
}) => captureChromeApp(
  tester,
  route: route,
  viewport: viewport,
  surface: 'overlay-toast',
  state: state,
  overrides: [..._chrome(viewport), ...overrides],
  afterSettle: (app) async {
    show(app);
    // Focus on the call dock's mic button would leave its tooltip showing.
    FocusManager.instance.primaryFocus?.unfocus();
    // The entrance ticker's first frame is its own t=0, so it needs one to start.
    await app.tester.pump();
  },
);

void _stack(ChromeApp app) {
  _toast(app, 'Saved kickoff-notes.pdf.', AppToastSeverity.success);
  _toast(app, 'Message link copied.');
  _toast(app, 'Image copied.', AppToastSeverity.success);
  _toast(app, 'Forwarded to #design and 2 other channels.');
}

/// A second account, in a call, as the switcher's snapshot reports one.
Override _callElsewhere(String spaceName) {
  final server = ProviderContainer(
    overrides: [
      serverInfoProvider.overrideWith(
        (ref) async => api.Version(
          name: 'slim-m',
          version: '0.127.0',
          protocol: 1,
          spaceName: spaceName,
        ),
      ),
    ],
  );
  addTearDown(server.dispose);
  final entry = AccountEntry(
    account: Account.forServer(Uri.parse('https://games.example.org')),
    container: server,
    active: false,
    signedIn: true,
    unread: AccountUnread.none,
    inCall: true,
  );
  return accountsSnapshotProvider.overrideWith(
    (ref) => AccountsSnapshot(callElsewhere: entry),
  );
}

Future<void> _pill(
  WidgetTester tester,
  String viewport,
  String? state,
  String spaceName,
) => captureChromeApp(
  tester,
  route: '/channels/c-general',
  viewport: viewport,
  surface: 'overlay-account-call-pill',
  state: state,
  overrides: [..._chrome(viewport), _callElsewhere(spaceName)],
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    group('overlay-toast, $viewport', () {
      testWidgets(
        'single',
        (tester) => _toasts(
          tester,
          viewport,
          'single',
          (app) => _toast(app, 'Message link copied.'),
        ),
      );

      testWidgets(
        'stacked',
        (tester) => _toasts(tester, viewport, 'stacked', _stack),
      );

      testWidgets(
        'above dock',
        (tester) => _toasts(
          tester,
          viewport,
          'above-dock',
          (app) {
            _toast(app, 'Saved kickoff-notes.pdf.', AppToastSeverity.success);
            _toast(app, 'Message link copied.');
          },
          route: '/channels/c-main',
          overrides: [
            voiceControllerProvider.overrideWith(
              (ref) => SnapshotVoiceController(
                ref,
                // The fixture's fixed start date reads as a call months long.
                connectedCallState.copyWith(
                  connectedAt: DateTime.now().subtract(
                    const Duration(minutes: 14, seconds: 32),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });

    group('overlay-account-call-pill, $viewport', () {
      testWidgets(
        'default',
        (tester) => _pill(tester, viewport, null, 'Game Night'),
      );

      testWidgets(
        'long name',
        (tester) => _pill(
          tester,
          viewport,
          'long-name',
          'Riverside Retro Gaming and Board Game Nights (Fridays)',
        ),
      );
    });
  }

  testWidgets(
    'dialog-windows-adopt-confirm, desktop',
    (tester) => captureChromeApp(
      tester,
      route: '/channels/c-general',
      viewport: 'desktop',
      surface: 'dialog-windows-adopt-confirm',
      overrides: desktopChromeOverrides(),
      afterSettle: (app) async {
        final navigator = app.router.routerDelegate.navigatorKey;
        unawaited(confirmWindowsAdopt(navigator.currentContext!));
        await app.tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Move and update'), findsOneWidget);
      },
    ),
  );
}
