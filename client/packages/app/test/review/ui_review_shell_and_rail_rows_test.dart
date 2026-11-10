// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of the menus a rail row opens: a channel row (text, voice,
/// a temporary room, the Notifications submenu) and a direct-message row.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// no overflow.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_shell_and_rail_data.dart';
import 'ui_review_shell_and_rail_actions.dart';
import 'ui_review_shell_and_rail_support.dart';

ShellStep _openRow(ShellWindow window, Finder Function() row) =>
    (tester, scene) => openRowMenu(tester, window, row());

void main() {
  setUpAll(loadRealFonts);

  for (final window in ShellWindow.values) {
    group('menu-channel-row, ${window.slug}', () {
      for (final (state, row, overrides) in <(String, String, List<Override>)>[
        ('text-member', 'random', [meOverride(memberPermissions)]),
        ('text-manager', 'random', const []),
        ('voice-member', 'Lounge', [meOverride(memberPermissions)]),
        ('temp-room-owner', "Nick's room", [meOverride(memberPermissions)]),
      ]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'menu-channel-row',
              state: state,
              overrides: overrides,
              seed: seedBusyRailWithUnread,
              arrange: _openRow(window, () => railText(row)),
            ),
          );
        });
      }

      testWidgets('notifications-submenu', (tester) async {
        await shootShell(
          tester,
          window,
          ShellCase(
            surface: 'menu-channel-row',
            state: 'notifications-submenu',
            seed: seedBusyRailWithUnread,
            arrange: (tester, scene) async {
              await openRowMenu(tester, window, railText('random'));
              await tester.tap(find.text('Notifications'));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 350));
            },
          ),
        );
      });
    });

    group('menu-dm-row, ${window.slug}', () {
      for (final (state, row) in [
        ('dm', 'Ada Lovelace'),
        ('group-dm', 'Ada and Christoph'),
      ]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'menu-dm-row',
              state: state,
              seed: seedBusyRailWithUnread,
              arrange: _openRow(window, () => railText(row)),
            ),
          );
        });
      }

      testWidgets('personal-space', (tester) async {
        await shootShell(
          tester,
          window,
          ShellCase(
            surface: 'menu-dm-row',
            state: 'personal-space',
            seed: seedBusyRailWithUnread,
            arrange: (tester, scene) async {
              await tester.tap(find.bySemanticsLabel('Personal space options'));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 350));
            },
          ),
        );
      });

      testWidgets('blocked', (tester) async {
        await shootShell(
          tester,
          window,
          ShellCase(
            surface: 'menu-dm-row',
            state: 'blocked',
            seed: seedBusyRailWithUnread,
            arrange: (tester, scene) async {
              unawaited(
                scene.container.read(blocksProvider.notifier).block('user-ada'),
              );
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 100)),
              );
              await tester.pump();
              await openRowMenu(tester, window, railText('Ada Lovelace'));
            },
          ),
        );
      });
    });
  }
}
