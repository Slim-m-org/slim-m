// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The startup splash on desktop and on a phone, for the design review.
///
/// `StartupApp` pins `AppTokens.dark`, so every capture here is dark only.
/// The desktop one renders at the splash window's own size; it is named
/// `desktop` because that is the platform, not the window.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_app/src/widgets/launch_cover.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'app_chrome_support.dart';

const _phases = [
  'Restoring session',
  'Loading preferences',
  'Checking for updates',
  'Connecting',
];

final _prompt = StartupPrompt(
  title: 'Version 0.127.0 is available',
  detail: 'Update with your package manager: sudo dnf upgrade slim-m-client',
  primaryLabel: 'Get update',
  onPrimary: () {},
  secondaryLabel: 'Not now',
  onSecondary: () {},
);

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _frame(WidgetTester tester, Widget app) =>
    tester.pumpWidget(RepaintBoundary(key: snapshotBoundary, child: app));

/// Feeds each phase in turn, then lets the lattice finish its sequence.
Future<void> _runThrough(
  WidgetTester tester,
  Widget Function(String status) app,
) async {
  for (final phase in _phases) {
    await _frame(tester, app(phase));
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _capture(
  WidgetTester tester,
  String state,
  String viewport,
) async {
  final name = chromeName(
    'app-startup-splash',
    state: state,
    viewport: viewport,
    theme: 'dark',
  );
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

/// Mid-fade on purpose: the settled end of a leaving splash is a blank panel.
///
/// The settle check would wait the fade out, so this skips it and asserts the
/// checklist is still legible instead.
Future<void> _captureMidFade(WidgetTester tester, String viewport) async {
  await tester.pump(const Duration(milliseconds: 90));
  expect(renderedText(tester), contains('Connecting'));
  await writeSnapshot(
    tester,
    chromeName(
      'app-startup-splash',
      state: 'leaving',
      viewport: viewport,
      theme: 'dark',
    ),
  );
  expect(tester.takeException(), isNull);
}

Widget _cover(Widget splash) => Builder(
  builder: (context) => MediaQuery.fromView(
    view: View.of(context),
    child: LaunchCover(
      covered: true,
      cover: splash,
      child: const SizedBox.shrink(),
    ),
  ),
);

void main() {
  setUpAll(loadRealFonts);

  final splash = Size(
    DesktopWindowShell.splashWindowSize.width,
    DesktopWindowShell.splashWindowSize.height,
  );

  group('desktop splash window', () {
    testWidgets('running', (tester) async {
      await _size(tester, splash);
      await _runThrough(tester, (status) => StartupApp(status: status));
      await _capture(tester, 'running', 'desktop');
    });

    testWidgets('prompt', (tester) async {
      await _size(tester, splash);
      await _frame(tester, StartupApp(prompt: _prompt));
      await tester.pump(const Duration(milliseconds: 1100));
      await _capture(tester, 'prompt', 'desktop');
    });

    testWidgets('leaving', (tester) async {
      await _size(tester, splash);
      await _runThrough(tester, (status) => StartupApp(status: status));
      await _frame(
        tester,
        const StartupApp(status: 'Connecting', leaving: true),
      );
      await _captureMidFade(tester, 'desktop');
    });
  });

  group('phone launch cover', () {
    testWidgets('running', (tester) async {
      await _size(tester, reviewPhone);
      await _runThrough(tester, (status) => _cover(StartupApp(status: status)));
      await _capture(tester, 'running', 'phone');
    });

    testWidgets('leaving', (tester) async {
      await _size(tester, reviewPhone);
      await _runThrough(tester, (status) => _cover(StartupApp(status: status)));
      await _frame(
        tester,
        _cover(const StartupApp(status: 'Connecting', leaving: true)),
      );
      await _captureMidFade(tester, 'phone');
    });
  });
}
