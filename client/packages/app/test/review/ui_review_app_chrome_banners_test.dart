// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The banners that sit above the shell: an update waiting, a self-update that
/// failed or rolled back, the first-run tray notice, and a failed download.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; the overflow check runs
/// everywhere.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/first_run_tray_notice.dart';
import 'package:slimm_app/src/desktop/self_update/android_apk_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/update_available_banner.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/widgets/banner_host_layout.dart';
import 'package:slimm_app/src/widgets/transfer_meter.dart';

import '../ui_snapshot_support.dart';
import 'app_chrome_support.dart';

const _route = '/channels/c-general';

/// An Android phone's banner: the one phone build that polls for updates.
Widget _phoneBanner(BuildContext context, Widget app) => BannerHostLayout(
  banner: const SafeArea(
    bottom: false,
    child: UpdateAvailableBanner(restartApplies: false),
  ),
  child: app,
);

Future<void> _desktopBanner(
  WidgetTester tester, {
  required String surface,
  String? state,
  bool frameless = true,
  List<Override> more = const [],
}) => captureChromeApp(
  tester,
  route: _route,
  viewport: 'desktop',
  surface: surface,
  state: state,
  overrides: [
    ...desktopChromeOverrides(frameless: frameless),
    ...more,
  ],
);

Override _failure(SelfUpdateFailure failure) =>
    selfUpdateFailureProvider.overrideWith((ref) => failure);

class _SeededDownloads extends DownloadsController {
  _SeededDownloads(this._tasks);

  final List<DownloadTask> _tasks;

  @override
  List<DownloadTask> build() => _tasks;
}

DownloadTask _failedDownload(int id, String filename, int size, String why) =>
    DownloadTask(
      id: id,
      attachment: api.Attachment(
        id: 'att-$id',
        filename: filename,
        contentType: 'application/octet-stream',
        size: size,
      ),
      meter: TransferMeter(),
      phase: DownloadPhase.failed,
      message: why,
    );

final _oneFailure = [
  _failedDownload(
    1,
    'kickoff-notes.pdf',
    482113,
    'Could not download kickoff-notes.pdf: the server could not be reached. '
        'Nothing was changed.',
  ),
];

final _severalFailures = [
  ..._oneFailure,
  _failedDownload(
    2,
    'Win11_23H2_English_x64.iso',
    6442450944,
    'Win11_23H2_English_x64.iso is too large to save on this device.',
  ),
  _failedDownload(
    3,
    'team-offsite-recording-final-v3-reencoded-for-the-wiki.mp4',
    912340112,
    'Could not download team-offsite-recording-final-v3-reencoded-for-the-wiki.mp4: '
        'this server has no storage left. Tell an admin.',
  ),
];

Future<void> _downloads(
  WidgetTester tester,
  String viewport,
  String state,
  List<DownloadTask> tasks,
) => captureChromeApp(
  tester,
  route: _route,
  viewport: viewport,
  surface: 'banner-download-failure',
  state: state,
  overrides: [
    if (viewport == 'desktop') ...desktopChromeOverrides(),
    downloadsProvider.overrideWith(() => _SeededDownloads(tasks)),
  ],
);

void main() {
  setUpAll(loadRealFonts);

  group('banner-update-available', () {
    testWidgets(
      'available, desktop',
      (tester) => _desktopBanner(
        tester,
        surface: 'banner-update-available',
        state: 'available',
        frameless: false,
        more: [inSessionUpdateProvider.overrideWith((ref) => reviewUpdate)],
      ),
    );

    for (final busy in [false, true]) {
      testWidgets(
        '${busy ? 'installing' : 'available'}, phone',
        (tester) => captureChromeApp(
          tester,
          route: _route,
          viewport: 'phone',
          surface: 'banner-update-available',
          state: busy ? 'installing' : 'available',
          overrides: [
            inSessionUpdateProvider.overrideWith((ref) => reviewUpdate),
            if (busy) apkUpdateBusyProvider.overrideWith((ref) => true),
          ],
          wrap: _phoneBanner,
        ),
      );
    }
  });

  group('banner-self-update-failure', () {
    testWidgets(
      'failed',
      (tester) => _desktopBanner(
        tester,
        surface: 'banner-self-update-failure',
        state: 'failed',
        more: [
          _failure(
            const SelfUpdateFailure(
              SelfUpdateFailureKind.checksumMismatch,
              'The downloaded update did not match its checksum, so it was '
              'discarded.',
              detail:
                  'expected 9f2c41d0b7e8a35c6d1f0e4b2a97c83d5e6f1a0b4c7d8e92f3a5b6c7d8e9f0a1, '
                  'got 41d0b7e8a35c6d1f0e4b2a97c83d5e6f1a0b4c7d8e92f3a5b6c7d8e9f0a19f2c',
              releaseUrl: 'https://example.invalid/releases/0.128.0',
            ),
          ),
        ],
      ),
    );

    testWidgets(
      'rolled back',
      (tester) => _desktopBanner(
        tester,
        surface: 'banner-self-update-failure',
        state: 'rolled-back',
        more: [
          _failure(
            const SelfUpdateFailure(
              SelfUpdateFailureKind.rolledBack,
              'Version 0.128.0 did not start, so slim-m went back to the '
              'previous version.',
            ),
          ),
        ],
      ),
    );
  });

  group('banner-first-run-tray-notice', () {
    for (final (state, action) in [
      (null, CloseAction.hideToTray),
      ('taskbar', CloseAction.minimizeToTaskbar),
    ]) {
      testWidgets(
        'close action ${action.name}',
        (tester) => _desktopBanner(
          tester,
          surface: 'banner-first-run-tray-notice',
          state: state,
          more: [
            firstRunTrayNoticeCloseActionProvider.overrideWith((ref) => action),
          ],
        ),
      );
    }
  });

  group('banner-download-failure', () {
    for (final viewport in reviewViewports.keys) {
      testWidgets(
        'one, $viewport',
        (tester) => _downloads(tester, viewport, 'one', _oneFailure),
      );
      testWidgets(
        'several, $viewport',
        (tester) => _downloads(tester, viewport, 'several', _severalFailures),
      );
    }
  });
}
