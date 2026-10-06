// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The routed app under an active [DesktopChrome] must keep following the
/// window size and the motion preference, not freeze at the first values.
///
/// Mounts the real `appChromeBuilder` with the shell active, which no other
/// test does, and records what a descendant of the chrome reads.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/display_preferences.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/fake_desktop_window_port.dart';

typedef _Seen = ({LayoutClass layout, double width, bool reduceMotion});

void main() {
  Future<ProviderContainer> pumpActiveChrome(
    WidgetTester tester,
    List<_Seen> seen,
  ) async {
    DesktopWindowShell.debugPort = FakeDesktopWindowPort();
    DesktopWindowShell.debugActivate(frameless: true);
    addTearDown(DesktopWindowShell.debugReset);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        // The chrome keeps the real watcher alive; its periodic timer is not under test.
        updateWatcherProvider.overrideWith(
          (ref) => UpdateWatcher(ref, shouldRun: () => false),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          builder: appChromeBuilder,
          home: Builder(
            builder: (context) {
              seen.add((
                layout: LayoutClass.of(context),
                width: MediaQuery.sizeOf(context).width,
                reduceMotion: MediaQuery.disableAnimationsOf(context),
              ));
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('the routed app follows the window across both breakpoints', (
    tester,
  ) async {
    final seen = <_Seen>[];
    await pumpActiveChrome(tester, seen);
    expect(seen.last.layout, LayoutClass.expanded);
    expect(seen.last.width, 1400);

    tester.view.physicalSize = const Size(800, 900);
    await tester.pump();
    expect(
      seen.last.width,
      800,
      reason: 'MediaQuery under the chrome still reports the first width',
    );
    expect(seen.last.layout, LayoutClass.medium);

    tester.view.physicalSize = const Size(500, 900);
    await tester.pump();
    expect(seen.last.width, 500);
    expect(seen.last.layout, LayoutClass.compact);

    tester.view.physicalSize = const Size(1400, 900);
    await tester.pump();
    expect(seen.last.width, 1400);
    expect(seen.last.layout, LayoutClass.expanded);
  });

  testWidgets('the routed app follows the reduce-motion preference', (
    tester,
  ) async {
    final seen = <_Seen>[];
    final container = await pumpActiveChrome(tester, seen);
    expect(seen.last.reduceMotion, isFalse);

    container.read(motionPreferenceControllerProvider.notifier).state =
        MotionOverride.alwaysReduce;
    await tester.pump();
    expect(
      seen.last.reduceMotion,
      isTrue,
      reason: 'the motion override never reached the routed tree',
    );

    container.read(motionPreferenceControllerProvider.notifier).state =
        MotionOverride.neverReduce;
    await tester.pump();
    expect(seen.last.reduceMotion, isFalse);
  });
}
