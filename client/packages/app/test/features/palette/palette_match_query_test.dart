// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette's two match predicates. Neither had a test, and each
/// hides a rule worth pinning: an empty query matches everything (a blank
/// browse), matching is case-insensitive and substring, a member is found by
/// display name or username, and a personal space is found by the caller's own
/// display name - but only a personal space, and only when that name is known.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart';
import 'package:slimm_data/data.dart' show Channel;

Channel _channel(String name, {bool personal = false}) => Channel(
  id: 'c-$name',
  name: name,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: personal,
);

const _member = api.UserProfile(
  id: 'u1',
  username: 'priya_dev',
  displayName: 'Priya Nair',
  createdAt: 0,
);

void main() {
  group('channelMatchesQuery', () {
    test('an empty query matches every channel', () {
      expect(channelMatchesQuery(_channel('general'), ''), isTrue);
    });

    test('the name matches case-insensitively, as a substring', () {
      expect(channelMatchesQuery(_channel('General'), 'ener'), isTrue);
      expect(channelMatchesQuery(_channel('General'), 'GEN'), isTrue);
      expect(channelMatchesQuery(_channel('general'), 'xyz'), isFalse);
    });

    test('a personal space is found by the caller\'s own display name', () {
      expect(
        channelMatchesQuery(
          _channel('My space', personal: true),
          'ali',
          selfDisplayName: 'Alice',
        ),
        isTrue,
      );
    });

    test(
      'only a personal space is found that way, not an ordinary channel',
      () {
        expect(
          channelMatchesQuery(
            _channel('general'),
            'ali',
            selfDisplayName: 'Alice',
          ),
          isFalse,
        );
      },
    );

    test('a personal space is not found by self name when it is unknown', () {
      expect(
        channelMatchesQuery(_channel('My space', personal: true), 'ali'),
        isFalse,
      );
    });
  });

  group('memberMatchesQuery', () {
    test('an empty query matches every member', () {
      expect(memberMatchesQuery(_member, ''), isTrue);
    });

    test('the display name matches case-insensitively', () {
      expect(memberMatchesQuery(_member, 'nair'), isTrue);
    });

    test('the username matches too, since either is a name to type', () {
      expect(memberMatchesQuery(_member, 'dev'), isTrue);
    });

    test('a query matching neither name does not match', () {
      expect(memberMatchesQuery(_member, 'zzz'), isFalse);
    });
  });
}
