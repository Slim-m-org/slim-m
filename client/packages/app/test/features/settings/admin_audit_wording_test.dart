// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sentence for every audited action, and the name fallbacks for targets
/// that no longer exist.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/admin_audit_wording.dart';

api.AdminChange _change(
  String action, {
  int id = 1,
  String? target,
  Map<String, dynamic> detail = const {},
}) => api.AdminChange(
  id: id,
  actorId: 'a',
  action: action,
  targetId: target,
  detail: detail,
  createdAt: 0,
);

const _names = AuditNames(
  roles: {'r1': 'Moderators'},
  channels: {'c1': 'general'},
  categories: {'k1': 'Text'},
  emoji: {'e1': 'party'},
  users: {'u1': 'Ada'},
);

void main() {
  final table = <(api.AdminChange, String)>[
    (
      _change(
        'space.update',
        detail: {
          'fields': ['name', 'description'],
        },
      ),
      'changed space settings: name, description',
    ),
    (_change('space.update'), 'changed space settings'),
    (_change('space.join_gate'), 'changed who can join'),
    (_change('space.analytics'), 'changed usage analytics'),
    (_change('space.retention'), 'changed message retention'),
    (_change('space.canvas_cap'), 'changed the canvas limit'),
    (_change('space.screen_share'), 'changed the screen share limit'),
    (_change('space.link_previews'), 'changed link previews'),
    (_change('space.attachment_limit'), 'changed the attachment size limit'),
    (_change('space.setup_complete'), 'finished the first-run setup'),
    (_change('space.icon_set'), 'set the space icon'),
    (_change('space.icon_clear'), 'removed the space icon'),
    (_change('space.banner_set'), 'set the space banner'),
    (_change('space.banner_clear'), 'removed the space banner'),
    (
      _change('role.create', target: 'r2', detail: {'name': 'Helpers'}),
      'created role Helpers',
    ),
    (_change('role.reorder'), 'reordered roles'),
    (
      _change(
        'role.update',
        target: 'r1',
        detail: {
          'name': 'Moderators',
          'fields': ['name'],
        },
      ),
      'renamed role Moderators',
    ),
    (
      _change(
        'role.update',
        target: 'r1',
        detail: {
          'fields': ['permissions', 'color'],
        },
      ),
      'changed role Moderators: permissions, color',
    ),
    (_change('role.delete', target: 'r1'), 'deleted role Moderators'),
    (
      _change(
        'role.assign',
        target: 'u1',
        detail: {
          'params': {'role_id': 'r1'},
        },
      ),
      'gave role Moderators to Ada',
    ),
    (
      _change(
        'role.unassign',
        target: 'u1',
        detail: {
          'params': {'role_id': 'r1'},
        },
      ),
      'removed role Moderators from Ada',
    ),
    (
      _change('role.module_grant', target: 'r1'),
      'granted a module permission to role Moderators',
    ),
    (
      _change('role.module_revoke', target: 'r1'),
      'revoked a module permission from role Moderators',
    ),
    (
      _change('channel.create', target: 'c9', detail: {'name': 'lounge'}),
      'created #lounge',
    ),
    (_change('channel.reorder'), 'reordered channels'),
    (
      _change(
        'channel.update',
        target: 'c1',
        detail: {
          'name': 'general',
          'fields': ['name'],
        },
      ),
      'renamed #general',
    ),
    (
      _change(
        'channel.update',
        target: 'c1',
        detail: {
          'fields': ['topic'],
        },
      ),
      'changed #general: topic',
    ),
    (_change('channel.delete', target: 'c1'), 'deleted #general'),
    (
      _change('channel.retention', target: 'c1'),
      'changed retention on #general',
    ),
    (
      _change('channel.room', target: 'c1'),
      'changed room settings on #general',
    ),
    (
      _change('channel.overwrites', target: 'c1'),
      'changed permissions on #general',
    ),
    (
      _change('channel.overwrites_sync', target: 'c1'),
      'synced permissions on #general with its category',
    ),
    (
      _change('channel.overwrite_set', target: 'c1'),
      'set a permission override on #general',
    ),
    (
      _change('channel.overwrite_clear', target: 'c1'),
      'cleared a permission override on #general',
    ),
    (
      _change('category.create', target: 'k9', detail: {'name': 'Voice'}),
      'created category Voice',
    ),
    (
      _change(
        'category.update',
        target: 'k1',
        detail: {
          'name': 'Text',
          'fields': ['name'],
        },
      ),
      'renamed category Text',
    ),
    (_change('category.delete', target: 'k1'), 'deleted category Text'),
    (
      _change('category.overwrites', target: 'k1'),
      'changed permissions on category Text',
    ),
    (_change('invite.create', target: 'abc'), 'created an invite'),
    (_change('invite.revoke', target: 'abc'), 'revoked invite abc'),
    (_change('emoji.create', target: 'e1'), 'added :party:'),
    (_change('emoji.bulk_create'), 'added several emoji'),
    (_change('emoji.delete', target: 'e1'), 'deleted :party:'),
    (_change('module.install', target: 'polls'), 'installed module polls'),
    (_change('module.uninstall', target: 'polls'), 'removed module polls'),
    (_change('module.enable', target: 'polls'), 'turned on module polls'),
    (_change('module.disable', target: 'polls'), 'turned off module polls'),
    (
      _change('module.schedule_channel', target: 'polls'),
      'set the schedule channel for module polls',
    ),
    (_change('module_source.add'), 'added a module source'),
    (_change('module_source.remove'), 'removed a module source'),
  ];

  for (final (change, expected) in table) {
    test('${change.action}: $expected', () {
      expect(describeAdminChange(change, _names), expected);
    });
  }

  test('an unknown action falls back to the humanised action name', () {
    expect(
      describeAdminChange(_change('widget.do_thing'), _names),
      'widget do thing',
    );
  });

  group('deleted targets', () {
    test('use the name an earlier entry in the log recorded', () {
      final log = [
        _change('channel.delete', id: 3, target: 'gone'),
        _change(
          'channel.update',
          id: 2,
          target: 'gone',
          detail: {'name': 'renamed'},
        ),
        _change(
          'channel.create',
          id: 1,
          target: 'gone',
          detail: {'name': 'first'},
        ),
      ];
      final names = AuditNames(logged: AuditNames.loggedNames(log));
      expect(describeAdminChange(log.first, names), 'deleted #renamed');
    });

    test('fall back to a short generic when nothing names them', () {
      const empty = AuditNames();
      expect(
        describeAdminChange(_change('channel.delete', target: 'x'), empty),
        'deleted a channel',
      );
      expect(
        describeAdminChange(_change('role.delete', target: 'x'), empty),
        'deleted a role',
      );
      expect(
        describeAdminChange(_change('category.delete', target: 'x'), empty),
        'deleted a category',
      );
      expect(
        describeAdminChange(_change('emoji.delete', target: 'x'), empty),
        'deleted an emoji',
      );
      expect(
        describeAdminChange(_change('role.assign', target: 'x'), empty),
        'gave a role to a member',
      );
    });
  });
}
