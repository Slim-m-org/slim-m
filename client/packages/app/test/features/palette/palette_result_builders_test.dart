// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette result builders, tested for the logic that is theirs rather
/// than the match predicates': the result list is capped at
/// [paletteResultLimit], a member list lists everyone and drops the caller themselves (a DM with
/// yourself is Notes, listed under Channels), and Notes is found by its own
/// name or the caller's.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart';
import 'package:slimm_data/data.dart' show Channel;

Channel _channel(
  String name, {
  bool personal = false,
  String kind = 'text',
  String? dmMemberIds,
}) => Channel(
  id: 'c-$name',
  name: name,
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: personal,
  dmMemberIds: dmMemberIds,
);

api.UserProfile _member(String id) =>
    api.UserProfile(id: id, username: id, displayName: id, createdAt: 0);

void main() {
  group('buildChannelItems', () {
    test('a DM is found under Members, not repeated as a channel', () {
      final channels = [
        _channel('general'),
        _channel('Bob', kind: 'dm'),
        _channel('Notes', kind: 'dm', personal: true),
      ];

      final labels = buildChannelItems(channels, '').map((i) => i.label);

      expect(labels, ['general', 'Notes']);
      expect(buildChannelItems(channels, 'bob'), isEmpty);
    });

    test('caps the result list at paletteResultLimit', () {
      final channels = [for (var i = 0; i < 12; i++) _channel('chan-$i')];
      expect(buildChannelItems(channels, '').length, paletteResultLimit);
    });

    test('Notes is found by its own name and by the caller\'s name', () {
      final channels = [_channel('general'), _channel('Notes', personal: true)];

      expect(buildChannelItems(channels, 'not').map((i) => i.label), ['Notes']);
      expect(
        buildChannelItems(
          channels,
          'ada',
          selfDisplayName: 'Ada',
        ).map((i) => i.label),
        ['Notes'],
      );
    });
  });

  group('buildMemberItems', () {
    test('drops the caller themselves', () {
      final members = [_member('me'), _member('ana'), _member('bo')];
      final items = buildMemberItems(members, '', 'me');
      expect(items.map((i) => i.label), ['ana', 'bo']);
    });

    test('lists everyone, not only the first few', () {
      final members = [for (var i = 0; i < 12; i++) _member('m$i')];
      expect(buildMemberItems(members, '', 'self').length, 12);
    });

    test('a limit keeps the first few and ends in a row for the rest', () {
      final members = [for (var i = 0; i < 12; i++) _member('m$i')];
      var opened = 0;
      final items = buildMemberItems(
        members,
        '',
        'self',
        limit: paletteResultLimit,
        showAll: () => opened++,
      );
      expect(items.length, paletteResultLimit + 1);
      expect(items.last.label, 'Show all 12 people');
      expect(items.last.showsAllOf, 12);
    });

    test('a limit with no show-all callback just stops', () {
      final members = [for (var i = 0; i < 12; i++) _member('m$i')];
      expect(buildMemberItems(members, '', 'self', limit: 5).length, 5);
    });

    test('puts the people who are around ahead of those who are not', () {
      final members = [_member('asleep'), _member('here'), _member('off')];
      final items = buildMemberItems(members, '', 'me', around: {'here'});
      expect(items.map((i) => i.label), ['here', 'asleep', 'off']);
    });
  });

  group('buildGroupDmItems', () {
    final group = _channel('Ana, Bo', kind: 'dm', dmMemberIds: 'me,ana,bo');

    test('finds a group chat by its name', () {
      final channels = [_channel('general'), group];

      expect(buildGroupDmItems(channels, 'bo').map((i) => i.label), [
        'Ana, Bo',
      ]);
      expect(buildGroupDmItems(channels, 'zzz'), isEmpty);
    });

    test('a one-to-one DM is still found under People only', () {
      final channels = [_channel('Bob', kind: 'dm', dmMemberIds: null)];

      expect(buildGroupDmItems(channels, ''), isEmpty);
    });
  });
}
