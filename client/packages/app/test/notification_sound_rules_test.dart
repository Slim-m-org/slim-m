// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pure decision logic behind which chime (if any) an event deserves,
/// with no provider container, fake stream, or widget involved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_rules.dart';

void main() {
  group('channelEarnsASound', () {
    test('no override at all earns a sound, the pre-feature default', () {
      expect(
        channelEarnsASound(
          channelOverride: null,
          isDm: false,
          mentionsSelf: false,
        ),
        isTrue,
      );
    });

    test('a mute override silences a plain message', () {
      expect(
        channelEarnsASound(
          channelOverride: api.NotificationPreference.nothing,
          isDm: false,
          mentionsSelf: false,
        ),
        isFalse,
      );
    });

    test('a mute override silences even a real mention', () {
      expect(
        channelEarnsASound(
          channelOverride: api.NotificationPreference.nothing,
          isDm: false,
          mentionsSelf: true,
        ),
        isFalse,
      );
    });

    test('a mute override silences even a DM', () {
      expect(
        channelEarnsASound(
          channelOverride: api.NotificationPreference.nothing,
          isDm: true,
          mentionsSelf: false,
        ),
        isFalse,
      );
    });

    test('a mentions-only override skips a plain message', () {
      expect(
        channelEarnsASound(
          channelOverride: api.NotificationPreference.mentions,
          isDm: false,
          mentionsSelf: false,
        ),
        isFalse,
      );
    });

    test('a mentions-only override still catches a real mention', () {
      expect(
        channelEarnsASound(
          channelOverride: api.NotificationPreference.mentions,
          isDm: false,
          mentionsSelf: true,
        ),
        isTrue,
      );
    });

    test('a mentions-only override still wakes for a plain DM', () {
      expect(
        channelEarnsASound(
          channelOverride: api.NotificationPreference.mentions,
          isDm: true,
          mentionsSelf: false,
        ),
        isTrue,
      );
    });
  });

  group('messageEarnsASound', () {
    test('a message from someone else earns a sound', () {
      expect(
        messageEarnsASound(
          authorId: 'author',
          selfId: 'me',
          authorBlocked: false,
        ),
        isTrue,
      );
    });

    test('this device\'s own message never earns a sound', () {
      expect(
        messageEarnsASound(authorId: 'me', selfId: 'me', authorBlocked: false),
        isFalse,
      );
    });

    test('a blocked author\'s message never earns a sound', () {
      expect(
        messageEarnsASound(
          authorId: 'author',
          selfId: 'me',
          authorBlocked: true,
        ),
        isFalse,
      );
    });

    test('an anonymised author (no id left) never earns a sound', () {
      expect(
        messageEarnsASound(authorId: null, selfId: 'me', authorBlocked: false),
        isFalse,
      );
    });
  });

  group('messageSoundKind', () {
    test('a DM is always the direct-message chime', () {
      expect(
        messageSoundKind(isDm: true, mentionsSelf: true),
        NotificationSound.directMessage,
      );
    });

    test('a mention in a non-DM channel is the mention chime', () {
      expect(
        messageSoundKind(isDm: false, mentionsSelf: true),
        NotificationSound.mention,
      );
    });

    test('an ordinary non-DM message is the group-message chime', () {
      expect(
        messageSoundKind(isDm: false, mentionsSelf: false),
        NotificationSound.groupMessage,
      );
    });
  });

  group('diffRoster', () {
    test('a null baseline is a snapshot: no joins or leaves either way', () {
      final diff = diffRoster(null, {'a', 'b'});
      expect(diff.joined, isEmpty);
      expect(diff.left, isEmpty);
      expect(diff.baseline, {'a', 'b'});
    });

    test('a newcomer against a real baseline is a join', () {
      final diff = diffRoster({'a'}, {'a', 'b'});
      expect(diff.joined, {'b'});
      expect(diff.left, isEmpty);
    });

    test('someone missing from a real baseline is a leave', () {
      final diff = diffRoster({'a', 'b'}, {'a'});
      expect(diff.joined, isEmpty);
      expect(diff.left, {'b'});
    });

    test('an unchanged roster reports neither', () {
      final diff = diffRoster({'a', 'b'}, {'a', 'b'});
      expect(diff.joined, isEmpty);
      expect(diff.left, isEmpty);
    });
  });
}
