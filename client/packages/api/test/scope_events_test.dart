// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Frame-parsing coverage for the role, overwrite, and channel WebSocket
/// events (`RoleChanged`, `MemberRoleChanged`, `ChannelCreated`,
/// `ChannelUpdated`, `ChannelDeleted`, `OverwriteChanged`): the client half of
/// the 2026-07-30 audit's fan-out finding, split out of `new_routes_test.dart`
/// rather than added there so that file stays under its recorded budget.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  group('role, overwrite, and channel WebSocket frames', () {
    test('role.changed decodes to RoleChanged carrying only the id', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'role.changed',
        'role_id': 'r',
      }));
      expect(event, isA<RoleChanged>());
      expect((event! as RoleChanged).roleId, 'r');
    });

    test('member.role_changed decodes both ids', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'member.role_changed',
        'user_id': 'u',
        'role_id': 'r',
      }));
      expect(event, isA<MemberRoleChanged>());
      final changed = event! as MemberRoleChanged;
      expect(changed.userId, 'u');
      expect(changed.roleId, 'r');
    });

    test('channel.created and channel.updated decode the full channel', () {
      final channelJson = {
        'id': 'c',
        'name': 'general',
        'kind': 'text',
        'created_at': 1,
        'topic': null,
      };
      final created = ServerEvent.parse(jsonEncode({
        'type': 'channel.created',
        'channel': channelJson,
      }));
      expect(created, isA<ChannelCreated>());
      expect((created! as ChannelCreated).channel.name, 'general');

      final updated = ServerEvent.parse(jsonEncode({
        'type': 'channel.updated',
        'channel': channelJson,
      }));
      expect(updated, isA<ChannelUpdated>());
      expect((updated! as ChannelUpdated).channel.id, 'c');
    });

    test('channel.deleted decodes to ChannelDeleted', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'channel.deleted',
        'channel_id': 'c',
      }));
      expect(event, isA<ChannelDeleted>());
      expect((event! as ChannelDeleted).channelId, 'c');
    });

    test(
        'overwrite.changed decodes to OverwriteChanged carrying only the '
        'channel id', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'overwrite.changed',
        'channel_id': 'c',
      }));
      expect(event, isA<OverwriteChanged>());
      expect((event! as OverwriteChanged).channelId, 'c');
    });

    test('a known type with the wrong shape asks for a resync, not a crash',
        () {
      // role.changed missing role_id entirely.
      expect(
        ServerEvent.parse(jsonEncode({'type': 'role.changed'})),
        isA<ErrorEvent>(),
      );
    });
  });
}
