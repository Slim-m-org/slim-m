// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures for the Space sheets opened from an admin pane: create
/// role, add emoji, install access for a module and the two bot editors.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/bot_permissions_sheet.dart';
import 'package:slimm_app/src/features/settings/screens/admin/bot_prefix_sheet.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_install_access_sheet.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_add_dialog.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_intake.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_create_sheet.dart';
import 'package:slimm_app/src/permissions.dart';

import '../dock_manifest_fixture.dart';
import '../features/settings/emoji_add_harness.dart';
import '../ui_snapshot_support.dart';
import 'ui_review_settings_personal_and_space_photo.dart';
import 'ui_review_settings_personal_and_space_support.dart';

Finder get _field => find.byWidgetPredicate((w) => w is EditableText);

Future<void> _tapText(WidgetTester tester, String label) async {
  final target = find.text(label).last;
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _names = [
  ('party_parrot', Color(0xFF7BC47F)),
  ('shipit', Color(0xFFE0A030)),
  ('thonk', Color(0xFFE8C547)),
  ('ship-it-squirrel', Color(0xFFB5835A)),
];

Future<List<EmojiPick>> _picks(WidgetTester tester) async => [
  for (final (name, colour) in _names)
    emojiPick('$name.png', await reviewEmojiPng(tester, colour)),
];

const _bot = api.Bot(
  userId: 'bot-helper',
  username: 'helper',
  displayName: 'Helper',
  createdAt: 0,
  tokenName: 'Helper',
  tokenLastUsedAt: 1000,
  roleId: 'role-helper',
  permissions: Perm.sendMessages | Perm.viewChannel | Perm.addReactions,
  prefix: '!',
  online: true,
);

final _manifest = api.DockManifest.fromJson(
  dockManifestJson(
    'ladder',
    '1.0.0',
    capabilities: const [
      'kv.store',
      'message.post',
      'net.fetch',
      'schedule',
      'events',
    ],
    network: const {
      'hosts': ['api.example.com', 'cdn.example.com'],
      'local': false,
    },
  ),
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    for (final failing in const [false, true]) {
      final state = failing ? 'error' : 'default';
      testWidgets('sheet-create-role $state at $viewport', (tester) async {
        await reviewOverlay(
          tester,
          surface: 'sheet-create-role',
          state: state,
          viewport: viewport,
          overrides: [
            if (failing)
              reviewApi({
                'POST /roles': jsonAnswer({
                  'error': 'a role with that name already exists',
                }, 409),
              }),
          ],
          open: (context, ref) => showCreateRoleSheet(context),
          afterOpen: failing
              ? (t) async {
                  await t.enterText(_field.first, 'Moderator');
                  await t.pump();
                  await t.tap(find.text('Create role').last);
                  await _frames(t);
                }
              : null,
        );
      });
    }

    for (final state in const [
      'intake',
      'review',
      'conflicts',
      'uploading',
      'leave-confirm',
    ]) {
      testWidgets('dialog-emoji-add $state at $viewport', (tester) async {
        final gate = Completer<void>();
        final picks = state == 'intake' ? <EmojiPick>[] : await _picks(tester);
        final harness = EmojiHarness(
          existing: state == 'conflicts'
              ? [
                  for (final name in const ['party_parrot', 'shipit'])
                    api.CustomEmoji(
                      id: 'e-$name',
                      name: name,
                      createdAt: 0,
                      uploaderId: 'user-nick',
                    ),
                ]
              : const [],
          onBulk: (r) => emojiJson([
            for (final n in bulkNames(r)) emojiRow(n),
          ], status: 201),
        );
        if (state == 'uploading') harness.holdBulk = (_) => gate.future;
        await reviewOverlay(
          tester,
          surface: 'dialog-emoji-add',
          state: state,
          viewport: viewport,
          overrides: harness.overrides,
          open: (context, ref) => showEmojiAddDialog(context, initial: picks),
          afterOpen: (t) async {
            await settleImages(t);
            if (state == 'uploading') await _tapText(t, 'Create 4 emoji');
            if (state == 'leave-confirm') {
              await t.sendKeyEvent(LogicalKeyboardKey.escape);
              await _frames(t);
            }
          },
          beforeTeardown: (t) async {
            if (!gate.isCompleted) gate.complete();
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await _frames(t);
          },
        );
      });
    }

    testWidgets('sheet-dock-install-access default at $viewport', (
      tester,
    ) async {
      await reviewOverlay(
        tester,
        surface: 'sheet-dock-install-access',
        state: 'default',
        viewport: viewport,
        open: (context, ref) => showDockInstallAccessSheet(
          context,
          manifest: _manifest,
          approved: const {'kv.store', 'message.post'},
          localNetwork: false,
        ),
      );
    });

    testWidgets('sheet-bot-edit permissions at $viewport', (tester) async {
      await reviewOverlay(
        tester,
        surface: 'sheet-bot-edit',
        state: 'permissions',
        viewport: viewport,
        open: (context, ref) => showBotPermissionsSheet(context, _bot),
      );
    });

    for (final invalid in const [false, true]) {
      final state = invalid ? 'prefix-invalid' : 'prefix';
      testWidgets('sheet-bot-edit $state at $viewport', (tester) async {
        await reviewOverlay(
          tester,
          surface: 'sheet-bot-edit',
          state: state,
          viewport: viewport,
          overrides: [
            if (invalid)
              reviewApi({
                'PATCH /bots/bot-helper/prefix': jsonAnswer({
                  'error': 'another bot already answers to that prefix',
                }, 409),
              }),
          ],
          open: (context, ref) => showBotPrefixSheet(context, _bot),
          afterOpen: invalid
              ? (t) async {
                  await t.enterText(_field.last, '?');
                  await t.pump();
                  await t.tap(find.text('Save prefix'));
                  await _frames(t);
                }
              : null,
        );
      });
    }
  }
}
