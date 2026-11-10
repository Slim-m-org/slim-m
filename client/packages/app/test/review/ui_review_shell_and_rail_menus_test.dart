// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of the menus the rail's chrome opens: the Space header's,
/// the footer avatar's status menu, a category header's and the blank rail's.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// no overflow.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/server_info.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_shell_and_rail_data.dart';
import 'ui_review_shell_and_rail_actions.dart';
import 'ui_review_shell_and_rail_support.dart';

const _statusLine = 'Heads down on the release until 3pm';

Override _membersCanInvite() => serverInfoProvider.overrideWith(
  (ref) async => const api.Version(
    name: 'slim-m',
    version: '0.127.0',
    protocol: 1,
    spaceName: 'Pinewood Collective',
    membersCanInvite: true,
  ),
);

ShellStep _tap(Finder Function() target) => (tester, scene) async {
  await tester.tap(target());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
};

void main() {
  setUpAll(loadRealFonts);

  for (final window in ShellWindow.values) {
    group('menu-space-header, ${window.slug}', () {
      for (final (state, overrides) in [
        ('admin', const <Override>[]),
        ('member', [meOverride(memberPermissions)]),
        ('inviter', [meOverride(memberPermissions), _membersCanInvite()]),
      ]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'menu-space-header',
              state: state,
              overrides: overrides,
              seed: seedBusyRailWithUnread,
              arrange: _tap(() => find.bySemanticsLabel('Space menu')),
            ),
          );
        });
      }
    });

    group('menu-presence, ${window.slug}', () {
      for (final (state, status) in [
        ('default', null),
        ('with-status', _statusLine),
      ]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'menu-presence',
              state: state,
              overrides: [meOverride(memberPermissions, statusText: status)],
              seed: seedBusyRail,
              arrange: _tap(() => find.bySemanticsLabel('Change your status')),
            ),
          );
        });
      }
    });

    group('menu-category-header, ${window.slug}', () {
      for (final (state, overrides) in [
        ('member', [meOverride(memberPermissions)]),
        ('manager', const <Override>[]),
      ]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'menu-category-header',
              state: state,
              overrides: overrides,
              seed: seedBusyRailWithUnread,
              arrange: (tester, scene) =>
                  openRowMenu(tester, window, railText('Text')),
            ),
          );
        });
      }
    });

    testWidgets('menu-rail-background, ${window.slug}', (tester) async {
      await shootShell(
        tester,
        window,
        ShellCase(
          surface: 'menu-rail-background',
          arrange: (tester, scene) async {
            // Below the last fixture row: the blank band only a manager's rail makes a target.
            const blank = Offset(120, 640);
            if (window.isPhone) {
              await tester.longPressAt(blank);
            } else {
              await tester.tapAt(
                blank,
                buttons: kSecondaryButton,
                kind: PointerDeviceKind.mouse,
              );
            }
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          },
        ),
      );
    });
  }
}
