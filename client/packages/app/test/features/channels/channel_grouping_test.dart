// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the ordering shared between the rail's sections and the
/// next/previous-channel shortcuts.
///
/// The defect these pin: `orderedChannels` kept a DM group in raw listing
/// order while the rail drew another, so cycling and the rail disagreed. Notes
/// left the Direct messages list for the footer (decision 0111's 2026-11-16
/// section), and cycling must not land on something the list does not show.
///
/// Grouping is by category now, not by kind - see docs/decisions/
/// 0006-channel-categories.md - so a channel of any kind may sit in any
/// category.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_grouping.dart';
import 'package:slimm_data/data.dart';

Channel _channel(
  String id, {
  String kind = 'text',
  bool isPersonalSpace = false,
  String? categoryId,
  int position = 0,
  bool? createsRooms,
  String? roomLobbyId,
}) => Channel(
  id: id,
  name: id,
  kind: kind,
  createdAt: 0,
  position: position,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: isPersonalSpace,
  categoryId: categoryId,
  createsRooms: createsRooms,
  roomOwnerId: roomLobbyId == null ? null : 'owner',
  roomLobbyId: roomLobbyId,
);

ChannelCategoryRow _category(String id, {int position = 0}) =>
    ChannelCategoryRow(id: id, name: id, position: position);

void main() {
  group('railDirectMessages', () {
    test('lists every DM but Notes, in listing order', () {
      final dm1 = _channel('dm1', kind: 'dm');
      final personal = _channel('personal', kind: 'dm', isPersonalSpace: true);
      final dm2 = _channel('dm2', kind: 'dm');

      final dms = railDirectMessages([dm1, personal, _channel('text'), dm2]);

      expect(dms.map((c) => c.id), ['dm1', 'dm2']);
    });
  });

  group('orderedChannels', () {
    test('groups direct messages first, then uncategorised, then each '
        'category in its own position order', () {
      final voiceCat = _category('voice-cat', position: 1);
      final textCat = _category('text-cat', position: 0);
      final ordered = orderedChannels(
        [
          _channel('voice1', kind: 'voice', categoryId: 'voice-cat'),
          _channel('text1', categoryId: 'text-cat'),
          _channel('loose', categoryId: null),
          _channel('dm1', kind: 'dm'),
        ],
        [textCat, voiceCat],
      );

      expect(ordered.map((c) => c.id), ['dm1', 'loose', 'text1', 'voice1']);
    });

    test('Notes is never in the cycle, which only visits listed rows', () {
      final dm = _channel('dm1', kind: 'dm');
      final personal = _channel('personal', kind: 'dm', isPersonalSpace: true);

      final ordered = orderedChannels([personal, dm, _channel('t')], const []);

      expect(
        ordered.map((c) => c.id),
        ['dm1', 't'],
        reason:
            'Notes is the footer button now, not a row next/previous '
            'could show as selected',
      );
    });

    test('a channel of any kind may sit in any category', () {
      final textCat = _category('text-cat');
      final ordered = orderedChannels(
        [_channel('v1', kind: 'voice', categoryId: 'text-cat')],
        [textCat],
      );
      expect(ordered.single.categoryId, 'text-cat');
    });
  });

  group('temporary rooms', () {
    test('each room sits right under its own lobby when positions '
        'interleave', () {
      final byCategory = channelsByCategory([
        _channel('lobby-a', kind: 'voice', position: 0, createsRooms: true),
        _channel('lobby-b', kind: 'voice', position: 1, createsRooms: true),
        _channel('room-b', kind: 'voice', position: 2, roomLobbyId: 'lobby-b'),
        _channel('room-a', kind: 'voice', position: 3, roomLobbyId: 'lobby-a'),
        _channel('general', position: 4),
      ]);

      expect(byCategory[null]!.map((c) => c.id), [
        'lobby-a',
        'room-a',
        'lobby-b',
        'room-b',
        'general',
      ]);
    });

    test('a room listed before its lobby still follows it', () {
      final rows = channelsByCategory([
        _channel('room', kind: 'voice', position: 0, roomLobbyId: 'lobby'),
        _channel('lobby', kind: 'voice', position: 1, createsRooms: true),
      ])[null]!;

      expect(rows.map((c) => c.id), ['lobby', 'room']);
      expect(isRoomUnderLobby(rows[1], rows), isTrue);
      expect(isRoomUnderLobby(rows[0], rows), isFalse);
    });

    test('a room whose lobby is in another category keeps its own place', () {
      final byCategory = channelsByCategory([
        _channel('lobby', kind: 'voice', createsRooms: true, categoryId: 'a'),
        _channel('room', kind: 'voice', roomLobbyId: 'lobby', categoryId: 'b'),
      ]);

      expect(byCategory['b']!.single.id, 'room');
      expect(
        isRoomUnderLobby(byCategory['b']!.single, byCategory['b']!),
        isFalse,
      );
    });
  });
}
