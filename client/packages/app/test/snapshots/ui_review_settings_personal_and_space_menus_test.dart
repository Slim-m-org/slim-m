// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures for the Space pickers and menus opened from inside a pane:
/// webhook rename and channel choice, the invite role grant, the Modules
/// overflow and the channel permissions pickers.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/webhooks_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/overwrite_target_picker.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/overwrite_target_picker_sheets.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_settings_personal_and_space_support.dart';

const _webhook = api.Webhook(
  id: 'wh-1',
  channelId: 'c-general',
  label: 'sonarr',
  createdAt: 0,
  createdByDisplayName: 'Nick',
);

Channel _channel(String id, String name, {String kind = 'text'}) => Channel(
  id: id,
  name: name,
  kind: kind,
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

final _channels = [
  _channel('c-general', 'general'),
  _channel('c-design', 'design'),
  _channel('c-release-notes', 'release-notes-and-changelog-discussion'),
  _channel('c-builds', 'builds'),
  _channel('c-main', 'main', kind: 'voice'),
  _channel('c-afk', 'afk', kind: 'voice'),
];

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _openRoleGrant(WidgetTester tester) =>
    _tap(tester, find.text('Role granted'));

Future<void> _chooseRoleThenReopen(WidgetTester tester) async {
  await _openRoleGrant(tester);
  await tester.tap(find.text('admin').last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await _openRoleGrant(tester);
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    testWidgets('sheet-webhook-rename rename at $viewport', (tester) async {
      await reviewOverlay(
        tester,
        surface: 'sheet-webhook-rename',
        state: 'rename',
        viewport: viewport,
        open: (context, ref) => showRenameWebhookSheet(context, _webhook),
      );
    });

    testWidgets('sheet-webhook-rename channel-picker at $viewport', (
      tester,
    ) async {
      await reviewRoute(
        tester,
        surface: 'sheet-webhook-rename',
        state: 'channel-picker',
        viewport: viewport,
        route: Routes.spaceSettingsPane('webhooks'),
        afterSettle: (t) => _tap(t, find.text('Choose a channel')),
      );
    });

    for (final (state, after) in <(String, ReviewAfter)>[
      ('none', _openRoleGrant),
      ('roles', _chooseRoleThenReopen),
    ]) {
      testWidgets('sheet-invite-role-grant $state at $viewport', (
        tester,
      ) async {
        await reviewRoute(
          tester,
          surface: 'sheet-invite-role-grant',
          state: state,
          viewport: viewport,
          route: Routes.spaceSettingsPane('invites'),
          freshPerTheme: true,
          afterSettle: after,
        );
      });
    }

    testWidgets('menu-dock-overflow default at $viewport', (tester) async {
      await reviewRoute(
        tester,
        surface: 'menu-dock-overflow',
        state: 'default',
        viewport: viewport,
        route: Routes.spaceSettingsPane('dock'),
        freshPerTheme: true,
        afterSettle: (t) =>
            _tap(t, find.bySemanticsLabel(RegExp('Module options'))),
      );
    });

    testWidgets('sheet-channel-permissions-picker channels at $viewport', (
      tester,
    ) async {
      await reviewOverlay(
        tester,
        surface: 'sheet-channel-permissions-picker',
        state: 'channels',
        viewport: viewport,
        open: (context, ref) => showAppSheet<Channel>(
          context,
          builder: (context) => ChannelPickerSheet(channels: _channels),
        ),
      );
    });

    testWidgets('sheet-channel-permissions-picker targets at $viewport', (
      tester,
    ) async {
      await reviewOverlay(
        tester,
        surface: 'sheet-channel-permissions-picker',
        state: 'targets',
        viewport: viewport,
        open: (context, ref) => showAppSheet<Object>(
          context,
          builder: (context) => const OverwriteTargetPicker(),
        ),
      );
    });
  }
}
