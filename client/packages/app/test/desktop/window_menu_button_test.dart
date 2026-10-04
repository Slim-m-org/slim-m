// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [WindowMenuButton] is the guaranteed quit control this pane exists to
/// close a real gap for: on a desktop with no tray host, the tray menu's
/// own "Quit slim-m" item never renders anywhere, so this has to be its own
/// reachable route, by mouse and by keyboard both.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/desktop/window_menu_button.dart';
import 'package:slimm_app/src/providers/auto_update_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/fake_desktop_window_port.dart';

const _update = ClientUpdate(
  version: '0.99.0',
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.rpm,
);

Future<SemanticsHandle> _pump(
  WidgetTester tester,
  FakeDesktopWindowPort port, {
  ClientUpdate? update,
  bool? autoUpdate,
}) async {
  SharedPreferences.setMockInitialValues({
    if (autoUpdate != null) autoUpdateKey: autoUpdate,
  });
  final handle = tester.ensureSemantics();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        inSessionUpdateProvider.overrideWith((ref) => update),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: WindowMenuButton(port: port),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return handle;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Window menu'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on tap and offers Quit slim-m', (tester) async {
    final handle = await _pump(tester, FakeDesktopWindowPort());

    expect(find.text('Quit slim-m'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Window menu'));
    await tester.pumpAndSettle();
    expect(find.text('Quit slim-m'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('tapping Quit slim-m calls destroy on the port exactly once', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    final handle = await _pump(tester, port);

    await tester.tap(find.bySemanticsLabel('Window menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit slim-m'));
    await tester.pumpAndSettle();

    expect(port.destroyCalls, 1);
    handle.dispose();
  });

  testWidgets('Escape closes the menu without quitting', (tester) async {
    final port = FakeDesktopWindowPort();
    final handle = await _pump(tester, port);

    await tester.tap(find.bySemanticsLabel('Window menu'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Quit slim-m'), findsNothing);
    expect(port.destroyCalls, 0);
    handle.dispose();
  });

  testWidgets(
    'the trigger and the open menu item are both real, focusable buttons '
    'in the actual dumped semantics tree, not merely painted to look like '
    'one',
    (tester) async {
      final handle = await _pump(tester, FakeDesktopWindowPort());

      final trigger = tester.getSemantics(find.bySemanticsLabel('Window menu'));
      final triggerData = trigger.getSemanticsData();
      expect(triggerData.flagsCollection.isButton, isTrue);
      expect(triggerData.flagsCollection.isFocused, isNot(Tristate.none));
      expect(triggerData.hasAction(SemanticsAction.tap), isTrue);

      await tester.tap(find.bySemanticsLabel('Window menu'));
      await tester.pumpAndSettle();

      final owner = tester.binding.renderViews.first.owner!;
      final dump = owner.semanticsOwner!.rootSemanticsNode!.toStringDeep();
      expect(dump, contains('Quit slim-m'));

      final quitItem = tester.getSemantics(
        find.widgetWithText(AppMenuItem, 'Quit slim-m'),
      );
      final quitItemData = quitItem.getSemanticsData();
      expect(quitItemData.flagsCollection.isButton, isTrue);
      expect(quitItemData.flagsCollection.isFocused, isNot(Tristate.none));
      expect(quitItemData.hasAction(SemanticsAction.tap), isTrue);

      handle.dispose();
    },
  );

  testWidgets('Restart sits above Quit and relaunches through the port once', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    final handle = await _pump(tester, port);
    await _open(tester);

    final restart = tester.getTopLeft(find.text('Restart slim-m'));
    final quit = tester.getTopLeft(find.text('Quit slim-m'));
    expect(restart.dy, lessThan(quit.dy), reason: 'quit stays last');

    await tester.tap(find.text('Restart slim-m'));
    await tester.pumpAndSettle();

    expect(port.relaunchCalls, 1);
    expect(port.destroyCalls, 0, reason: 'the port quits as part of relaunch');
    handle.dispose();
  });

  testWidgets('no Restart where this install cannot relaunch itself', (
    tester,
  ) async {
    final handle = await _pump(
      tester,
      FakeDesktopWindowPort()..canRelaunch = false,
    );
    await _open(tester);

    expect(find.text('Restart slim-m'), findsNothing);
    expect(find.text('Quit slim-m'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('no Update item until a newer build is actually known', (
    tester,
  ) async {
    final handle = await _pump(tester, FakeDesktopWindowPort());
    await _open(tester);

    expect(find.textContaining('update'), findsNothing);
    handle.dispose();
  });

  testWidgets('an rpm with auto-update on offers a restart that relaunches', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    final handle = await _pump(tester, port, update: _update, autoUpdate: true);
    await _open(tester);

    await tester.tap(find.text('Restart to update to 0.99.0'));
    await tester.pumpAndSettle();

    expect(port.relaunchCalls, 1);
    handle.dispose();
  });

  testWidgets('without auto-update the item points at the package manager', (
    tester,
  ) async {
    final handle = await _pump(
      tester,
      FakeDesktopWindowPort(),
      update: _update,
      autoUpdate: false,
    );
    await _open(tester);

    expect(
      find.text('Update 0.99.0 with your package manager'),
      findsOneWidget,
    );
    expect(find.textContaining('Restart to update'), findsNothing);
    handle.dispose();
  });

  test(
    'updateMenuAction restarts only for an rpm that will install itself',
    () {
      expect(
        updateMenuAction(_update, autoUpdate: true),
        UpdateMenuAction.restartToUpdate,
      );
      expect(
        updateMenuAction(_update, autoUpdate: false),
        UpdateMenuAction.packageManager,
      );
      expect(
        updateMenuAction(_update, autoUpdate: null),
        UpdateMenuAction.packageManager,
        reason: 'unanswered means the splash will ask, not install',
      );
      const flatpak = ClientUpdate(
        version: '0.99.0',
        releaseUrl: 'https://example.invalid/release',
        format: InstallFormat.flatpak,
      );
      expect(
        updateMenuAction(flatpak, autoUpdate: true),
        UpdateMenuAction.packageManager,
      );
    },
  );

  test('a self-applying tarball installs on tap and restarts once staged', () {
    const tarball = ClientUpdate(
      version: '0.99.0',
      releaseUrl: 'https://example.invalid/release',
      format: InstallFormat.tarball,
    );
    expect(
      updateMenuAction(tarball, selfApplies: true),
      UpdateMenuAction.installAndRestart,
    );
    expect(
      updateMenuAction(tarball, selfApplies: true, staged: '0.99.0'),
      UpdateMenuAction.restartToUpdate,
    );
    expect(
      updateMenuAction(tarball, selfApplies: true, staged: '0.98.0'),
      UpdateMenuAction.installAndRestart,
    );
    expect(updateMenuAction(tarball), UpdateMenuAction.openRelease);
  });
}
