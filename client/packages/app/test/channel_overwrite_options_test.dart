// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Each overwrite cell, for a role and for a member, reaches allow, deny and
/// inherit and saves exactly that (allow, deny) pair for that principal; and
/// the pane's own chrome: the chosen channel with a way to change it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_screen.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';

import 'roles_config_harness.dart';

final _channel = Channel(
  id: 'c-general',
  name: 'general',
  kind: 'text',
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

const _send = Perm.sendMessages;
const _react = Perm.addReactions;

api.Role _role(String id, {bool everyone = false}) => api.Role(
  id: id,
  name: id,
  permissions: 0,
  isEveryone: everyone,
  createdAt: 0,
);

/// A role holding an allow on send, a member holding a deny on send, and a
/// neutral cell (add reactions) on both.
Future<ConfigHarness> _open(WidgetTester tester, Widget child) async {
  final h = ConfigHarness(
    handler: (r) =>
        r.method == 'PUT' ? jsonOk({'overwrites': <Object>[]}) : null,
  );
  await h.pump(
    tester,
    child,
    size: const Size(1000, 1400),
    overrides: [
      rolesProvider.overrideWith(
        (ref) async => [_role('everyone', everyone: true), _role('mod')],
      ),
      membersProvider.overrideWith(
        (ref) async => [
          api.UserProfile(
            id: 'kiki',
            username: 'kiki',
            displayName: 'Kiki',
            createdAt: 0,
          ),
        ],
      ),
      channelOverwritesProvider(_channel.id).overrideWith(
        (ref) async => const [
          api.ChannelOverwrite(
            kind: api.OverwriteTarget.role,
            id: 'mod',
            allow: _send,
            deny: 0,
          ),
          api.ChannelOverwrite(
            kind: api.OverwriteTarget.member,
            id: 'kiki',
            allow: 0,
            deny: _send,
          ),
        ],
      ),
      myChannelPermissionsProvider(_channel.id).overrideWith((ref) => -1),
    ],
  );
  return h;
}

Finder _cell(String key, int bit) => find.byKey(ValueKey('cell:$key:$bit'));

Future<Map<String, dynamic>> _save(WidgetTester tester, ConfigHarness h) async {
  await tester.tap(find.text('Save changes'));
  await tester.pumpAndSettle();
  final put = h.writes.single;
  expect(put.method, 'PUT');
  final edits = (put.body! as Map)['overwrites'] as List;
  expect(edits, hasLength(1));
  return edits.single as Map<String, dynamic>;
}

void main() {
  const principals = {'role:mod': 'role', 'member:kiki': 'member'};

  for (final entry in principals.entries) {
    final key = entry.key;
    final id = key.split(':').last;

    testWidgets('${entry.value}: an inherit cell becomes allow', (
      tester,
    ) async {
      final h = await _open(tester, ChannelPermissionsGrid(channel: _channel));
      await tester.tap(_cell(key, _react));
      await tester.pumpAndSettle();
      final edit = await _save(tester, h);
      expect(edit['id'], id);
      expect(edit['allow'], _react | (key == 'role:mod' ? _send : 0));
      expect(edit['deny'], key == 'member:kiki' ? _send : 0);
    });

    testWidgets('${entry.value}: a second tap makes it deny', (tester) async {
      final h = await _open(tester, ChannelPermissionsGrid(channel: _channel));
      await tester.tap(_cell(key, _react));
      await tester.tap(_cell(key, _react));
      await tester.pumpAndSettle();
      final edit = await _save(tester, h);
      expect(edit['id'], id);
      expect(edit['allow'], key == 'role:mod' ? _send : 0);
      expect(edit['deny'], _react | (key == 'member:kiki' ? _send : 0));
    });

    testWidgets('${entry.value}: a third tap returns to inherit', (
      tester,
    ) async {
      await _open(tester, ChannelPermissionsGrid(channel: _channel));
      for (var i = 0; i < 3; i++) {
        await tester.tap(_cell(key, _react));
      }
      await tester.pumpAndSettle();
      expect(find.text('Save changes'), findsNothing);
    });
  }

  testWidgets('an existing allow cycled to inherit saves it cleared', (
    tester,
  ) async {
    final h = await _open(tester, ChannelPermissionsGrid(channel: _channel));
    await tester.tap(_cell('role:mod', _send));
    await tester.tap(_cell('role:mod', _send));
    await tester.pumpAndSettle();
    final edit = await _save(tester, h);
    expect(edit['id'], 'mod');
    expect(edit['allow'], 0);
    expect(edit['deny'], 0);
  });

  testWidgets('the pane shows the chosen channel with an All channels button', (
    tester,
  ) async {
    await _open(tester, ChannelPermissionsPane(initialChannel: _channel));
    expect(find.text('general'), findsWidgets);
    expect(find.text('Permission overwrites'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'All channels'), findsOneWidget);
  });

  testWidgets('a locked pane has no header or All channels button', (
    tester,
  ) async {
    await _open(
      tester,
      ChannelPermissionsPane(initialChannel: _channel, lockChannel: true),
    );
    expect(find.text('Permission overwrites'), findsNothing);
    expect(find.text('All channels'), findsNothing);
  });

  // The channel list itself is admin_unmounted_writes_test's 'every channel is listed'.
  testWidgets('with no channel the pane shows no grid yet', (tester) async {
    await _open(tester, const ChannelPermissionsPane());
    expect(find.text('Permission overwrites'), findsNothing);
    expect(find.byType(ChannelPermissionsGrid), findsNothing);
  });
}
