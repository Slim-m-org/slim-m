// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of the channel list as the phone's whole screen and the
/// docked desktop rail: an empty or loading list, then collapsed categories,
/// muted and mention rows and a lifted row.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// no overflow.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/channels/providers/collapsed_categories_preference.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_shell_and_rail_actions.dart';
import 'ui_review_shell_and_rail_data.dart';
import 'ui_review_shell_and_rail_support.dart';

const _phone = ShellWindow.phone;
const _desktop = ShellWindow.desktop;

void main() {
  setUpAll(loadRealFonts);

  group('shell-channel-list-phone', () {
    testWidgets('empty, for a manager', (tester) async {
      await shootShell(
        tester,
        _phone,
        const ShellCase(
          surface: 'shell-channel-list-phone',
          state: 'empty-manager',
          seed: emptyChannels,
        ),
      );
    });

    testWidgets('empty, for a member', (tester) async {
      await shootShell(
        tester,
        _phone,
        ShellCase(
          surface: 'shell-channel-list-phone',
          state: 'empty-member',
          overrides: [meOverride(Perm.viewChannel | Perm.sendMessages)],
          seed: emptyChannels,
        ),
      );
    });

    testWidgets('loading', (tester) async {
      await shootShell(
        tester,
        _phone,
        ShellCase(
          surface: 'shell-channel-list-phone',
          state: 'loading',
          scopedOverrides: [
            storeProvider.overrideWith(
              (ref) => Completer<MessageStore>().future,
            ),
          ],
        ),
      );
    });
  });

  group('shell-rail-docked', () {
    testWidgets('collapsed categories', (tester) async {
      await shootShell(
        tester,
        _desktop,
        ShellCase(
          surface: 'shell-rail-docked',
          state: 'collapsed-category',
          seed: seedBusyRailWithUnread,
          arrange: (tester, scene) async {
            final folds = scene.container.read(
              collapsedCategoriesProvider.notifier,
            );
            await tester.runAsync(() => folds.toggle('cat-projects'));
            await tester.runAsync(() => folds.toggle('cat-archive'));
          },
        ),
      );
    });

    testWidgets('unread, mentions and a muted channel', (tester) async {
      await shootShell(
        tester,
        _desktop,
        ShellCase(
          surface: 'shell-rail-docked',
          state: 'unread-mentions-muted',
          seed: seedBusyRailWithUnread,
          arrange: (tester, scene) async {
            scene.container
                .read(channelNotificationOverridesProvider.notifier)
                .applyRemote('c-random', api.NotificationPreference.nothing);
            scene.container
                .read(channelNotificationOverridesProvider.notifier)
                .applyRemote('c-roadmap', api.NotificationPreference.mentions);
          },
        ),
      );
    });

    testWidgets('empty, for a manager', (tester) async {
      await shootShell(
        tester,
        _desktop,
        const ShellCase(
          surface: 'shell-rail-docked',
          state: 'empty-manager',
          route: '/channels',
          seed: emptyChannels,
        ),
      );
    });

    testWidgets('a row lifted mid-reorder', (tester) async {
      TestGesture? held;
      await shootShell(
        tester,
        _desktop,
        ShellCase(
          surface: 'shell-rail-docked',
          state: 'reorder-carry',
          seed: seedBusyRail,
          remount: true,
          arrange: (tester, scene) async {
            final from = tester.getCenter(railText('design'));
            final to = tester.getCenter(railText('Lounge'));
            held = await tester.createGesture(kind: PointerDeviceKind.mouse);
            await held!.addPointer(location: from);
            await tester.pump();
            await held!.down(from);
            await tester.pump(const Duration(milliseconds: 400));
            for (var i = 1; i <= 12; i++) {
              await held!.moveTo(Offset.lerp(from, to, i / 12)!);
              await tester.pump(const Duration(milliseconds: 16));
            }
          },
          release: (tester, scene) async {
            await held?.up();
            await held?.removePointer();
          },
        ),
      );
    });
  });
}
