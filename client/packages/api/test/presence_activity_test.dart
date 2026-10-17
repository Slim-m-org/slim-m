// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The activity field on presence: read from a frame and a batch lookup, and
/// written back in the shape the server accepts.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('presence.changed carries an activity when the server sends one', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'presence.changed',
        'user_id': 'u1',
        'status': 'online',
        'activity': {
          'type': 'listening',
          'title': 'Song',
          'subtitle': 'Artist',
          'started_at': 1700000000000,
        },
      }),
    );
    final activity = (event as PresenceChanged).activity!;
    expect(activity.kind, ActivityKind.listening);
    expect(activity.title, 'Song');
    expect(activity.subtitle, 'Artist');
    expect(activity.startedAt, 1700000000000);
  });

  test('source and art survive the wire both ways', () {
    const art =
        'https://i.scdn.co/image/ab67616d0000b273bc2dd68b840b1d4b7c9e5ad9';
    final activity = PresenceActivity.tryFromJson({
      'type': 'listening',
      'title': 'Song',
      'source': 'Spotify',
      'art_url': art,
    })!;
    expect(activity.source, 'Spotify');
    expect(activity.artUrl, art);
    expect(activity.toJson(), containsPair('source', 'Spotify'));
    expect(activity.toJson(), containsPair('art_url', art));
  });

  test('art that is not a Spotify cover is dropped on read and on write', () {
    const id = 'ab67616d0000b273bc2dd68b840b1d4b7c9e5ad9';
    for (final url in [
      'http://i.scdn.co/image/$id',
      'https://evil.example/image/$id',
      'https://i.scdn.co/image/$id?x=1',
      'https://i.scdn.co.evil.example/image/$id',
      'https://i.scdn.co/image/${id.toUpperCase()}',
      'file:///home/me/cover.png',
    ]) {
      expect(isAllowedArtUrl(url), isFalse, reason: url);
      final read = PresenceActivity.tryFromJson({
        'type': 'listening',
        'title': 'Song',
        'art_url': url,
      })!;
      expect(read.artUrl, isNull, reason: url);
      expect(
        PresenceActivity(kind: ActivityKind.listening, title: 'S', artUrl: url)
            .toJson(),
        isNot(contains('art_url')),
        reason: url,
      );
    }
    expect(isAllowedArtUrl('https://i.scdn.co/image/$id'), isTrue);
  });

  test('a frame without one, or with an unknown kind, has no activity', () {
    for (final extra in <Map<String, Object?>>[
      {},
      {
        'activity': {'type': 'dancing', 'title': 'x'},
      },
      {
        'activity': {'type': 'playing', 'title': ''},
      },
    ]) {
      final event = ServerEvent.parse(
        jsonEncode({
          'type': 'presence.changed',
          'user_id': 'u1',
          'status': 'online',
          ...extra,
        }),
      );
      expect((event as PresenceChanged).activity, isNull);
    }
  });

  test('a batch lookup entry reads its activity', () {
    final status = PresenceStatus.fromJson({
      'user_id': 'u1',
      'status': 'away',
      'activity': {'type': 'playing', 'title': 'Game'},
    });
    expect(status.activity?.kind, ActivityKind.playing);
    expect(status.activity?.subtitle, isNull);
  });

  test('toJson omits what is unknown, matching the server schema', () {
    const activity = PresenceActivity(
      kind: ActivityKind.listening,
      title: 'Song',
    );
    expect(activity.toJson(), {'type': 'listening', 'title': 'Song'});
  });
}
