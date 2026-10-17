// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette result builders, tested for the logic that is theirs rather
/// than the match predicates': the result list is capped at
/// [paletteResultLimit], a member list drops the caller themselves (a DM with
/// yourself has its own rail row), and a hidden personal space stays out of a
/// blank browse but returns the moment a real query is typed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart';
import 'package:slimm_data/data.dart' show Channel;

Channel _channel(String name, {bool personal = false, String kind = 'text'}) =>
    Channel(
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

    test(
      'a hidden personal space is out of a blank browse but back on a query',
      () {
        final channels = [
          _channel('general'),
          _channel('space', personal: true),
        ];

        final browse = buildChannelItems(
          channels,
          '',
          personalSpaceHidden: true,
        );
        expect(browse.map((i) => i.label), ['general']);

        final searched = buildChannelItems(
          channels,
          'spa',
          personalSpaceHidden: true,
        );
        expect(searched.map((i) => i.label), ['space']);
      },
    );
  });

  group('buildMemberItems', () {
    test('drops the caller themselves', () {
      final members = [_member('me'), _member('ana'), _member('bo')];
      final items = buildMemberItems(members, '', 'me');
      expect(items.map((i) => i.label), ['ana', 'bo']);
    });

    test('caps the result list at paletteResultLimit', () {
      final members = [for (var i = 0; i < 12; i++) _member('m$i')];
      expect(buildMemberItems(members, '', 'self').length, paletteResultLimit);
    });
  });
}
