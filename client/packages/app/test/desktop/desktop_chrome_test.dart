// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [DesktopChrome] must pass its child through completely unwrapped while
/// [DesktopWindowShell.active] is false - the property every other widget
/// test in this package's tree shape depends on never changing, since
/// `flutter test` genuinely runs on Linux and nothing else distinguishes a
/// test run from a real desktop launch until the shell actually starts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_chrome.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/window_resize_frame.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/desktop_shell_fixture.dart';

void main() {
  testWidgets(
    'passes the child straight through when the shell was never started',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: DesktopChrome(child: Text('real content'))),
        ),
      );

      expect(find.text('real content'), findsOneWidget);
      // Exactly what was handed in: nothing started the shell, so no chrome wraps it.
      expect(find.byType(Column), findsNothing);
    },
  );

  testWidgets(
    'active chrome gives its text a real style, not the fallback underline',
    (tester) async {
      // The real placement: chrome in MaterialApp's builder, no Scaffold, so it must carry its own Material or the text inherits the fallback underline.
      final shell = shellFor(null, active: true, frameless: true);
      tester.view.physicalSize = const Size(1400, 880);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [desktopWindowShellProvider.overrideWithValue(shell)],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            builder: (context, child) => DesktopChrome(child: child!),
            home: const SizedBox.expand(),
          ),
        ),
      );

      final style = DefaultTextStyle.of(
        tester.element(find.text('slim-m')),
      ).style;
      expect(
        style.decoration,
        isNot(TextDecoration.underline),
        reason: 'chrome text inherited the fallback underline: no Material',
      );
      expect(DesktopChrome, isNotNull);
      expect(find.byType(Material), findsWidgets);
      expect(
        find.byType(WindowResizeFrame),
        findsOneWidget,
        reason: 'the frameless shell must offer edge/corner resize',
      );
    },
  );

  testWidgets('mounts no resize frame while active but not yet frameless', (
    tester,
  ) async {
    // Mirrors the macOS/Windows branch: active without frameless draws no title bar either, so nothing needs a resize frame on a window the OS still frames.
    final shell = shellFor(null, active: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopWindowShellProvider.overrideWithValue(shell)],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          builder: (context, child) => DesktopChrome(child: child!),
          home: const SizedBox.expand(),
        ),
      ),
    );

    expect(find.byType(WindowResizeFrame), findsNothing);
  });

  testWidgets("the title bar's window menu opens - the chrome carries an Overlay", (
    tester,
  ) async {
    // The window menu is an OverlayPortal; without the chrome's own Overlay it threw "No Overlay widget found" and never opened.
    final shell = shellFor(null, active: true, frameless: true);
    tester.view.physicalSize = const Size(1400, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopWindowShellProvider.overrideWithValue(shell)],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          builder: (context, child) => DesktopChrome(child: child!),
          home: const SizedBox.expand(),
        ),
      ),
    );

    await tester.tap(find.byIcon(AppIcons.moreVertical), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('Quit slim-m'), findsOneWidget);
    // The menu sizes to its content, not the window: a full-width band was the no-overlay symptom.
    final menu = tester.getSize(
      find
          .ancestor(
            of: find.text('Quit slim-m'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(menu.width, lessThan(300));
  });
}
